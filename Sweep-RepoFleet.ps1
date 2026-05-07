[CmdletBinding()]
param(
    [string[]]$Owners                          = @("{{YOUR_GH_USER_OR_ORG}}"),
    [string[]]$Repos                           = @(),
    [switch]$IncludePrivate,
    [switch]$IncludeForks,
    [switch]$IncludeArchived,
    [string[]]$IncludePatterns                 = @("*"),
    [string[]]$ExcludePatterns                 = @(),
    [string[]]$LanguageAllowlist               = @(),
    [string]$BranchPrefix                      = "chore/health-sweep",
    [string[]]$Reviewers                       = @("{{REVIEWER1}}","{{REVIEWER2}}"),
    [string[]]$Labels                          = @("maintenance","automated","health-sweep"),
    [int]$MaxParallel                          = 4,
    [switch]$DryRun,
    [switch]$SetupCI                           = $true,
    [switch]$SetupDependabot                   = $true,
    [switch]$SetupCodeQL                       = $true,
    [switch]$SetupPreCommit                    = $true,
    [switch]$UseDependabot                     = $true,
    [switch]$CleanOldBranches                  = $true,
    [switch]$CreatePR                          = $true,
    [switch]$Push                              = $true,
    [switch]$ConventionalCommits               = $true,
    [switch]$SignCommits                       = $false,
    [switch]$AutoInstall,
    [string]$ReportPath                        = (Join-Path $PWD "repo-sweep"),
    [int]$TimeoutPerRepoMinutes                = 30
)

function Write-Section($Msg){ Write-Output "==== $Msg ====" }

function Require-Tool {
    param([string]$Name,[string]$Check,[string]$InstallHint)
    if(-not (Get-Command $Check -ErrorAction SilentlyContinue)){
        if($AutoInstall -and (Get-Command winget -ErrorAction SilentlyContinue)){
            winget install --id $InstallHint --silent | Out-Null
        }else{
            throw "Missing tool: $Name. Install hint: $InstallHint"
        }
    }
}

function Test-Prerequisites {
    Write-Section "Checking prerequisites"
    Require-Tool git git.exe "Git.Git"
    Require-Tool gh gh.exe "GitHub.cli"
    Require-Tool node node.exe "OpenJS.Node"
    Require-Tool python python.exe "Python.Python.3.11"
    Require-Tool go go.exe "GoLang.Go"
    Require-Tool cargo cargo.exe "Rustlang.Rust.MSVC"
    Require-Tool dotnet dotnet.exe "Microsoft.DotNet.SDK.8"
    Require-Tool java java.exe "Microsoft.OpenJDK.17"
}

function Get-RepoList {
    $repos = @()
    if($Repos.Count -gt 0){
        $repos = $Repos
    }else{
        foreach($o in $Owners){
            $args = @("repo","list",$o,"--json","nameWithOwner,isPrivate,isFork,isArchived")
            if($IncludePrivate){ $args += "--private" }
            $json = gh @args | ConvertFrom-Json
            foreach($r in $json){
                if(!$IncludeForks -and $r.isFork){ continue }
                if(!$IncludeArchived -and $r.isArchived){ continue }
                $repos += $r.nameWithOwner
            }
        }
    }
    $filtered = $repos | Where-Object {
        $include = $true
        foreach($pat in $IncludePatterns){ if($_ -like $pat){ $include = $include } }
        foreach($pat in $ExcludePatterns){ if($_ -like $pat){ $include = $false } }
        $include
    }
    return $filtered | Sort-Object -Unique
}

function Invoke-RepoCommand {
    param([string]$Command,[string]$WorkingDir,[int]$Timeout)
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = "pwsh"
    $psi.Arguments = "-NoLogo -NoProfile -Command `$ErrorActionPreference='Stop';$Command"
    $psi.WorkingDirectory = $WorkingDir
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError  = $true
    $p = New-Object System.Diagnostics.Process
    $p.StartInfo = $psi
    $null = $p.Start()
    if(-not $p.WaitForExit($Timeout * 1000)){
        $p.Kill()
        return @{ ExitCode=1; StdOut=""; StdErr="Timeout" }
    }
    return @{ ExitCode=$p.ExitCode; StdOut=$p.StandardOutput.ReadToEnd(); StdErr=$p.StandardError.ReadToEnd() }
}

function New-Report($Path){ if(-not (Test-Path $Path)){ New-Item -ItemType Directory -Path $Path | Out-Null } }

function Detect-Languages($RepoPath){
    $langs = @()
    if(Test-Path (Join-Path $RepoPath "package.json")){ $langs += "Node" }
    if((Test-Path (Join-Path $RepoPath "pyproject.toml")) -or (Get-ChildItem $RepoPath -Filter "requirements*.txt")){ $langs += "Python" }
    if(Test-Path (Join-Path $RepoPath "go.mod")){ $langs += "Go" }
    if(Test-Path (Join-Path $RepoPath "Cargo.toml")){ $langs += "Rust" }
    if(Get-ChildItem $RepoPath -Filter "*.csproj" -Recurse){ $langs += "DotNet" }
    if(Test-Path (Join-Path $RepoPath "pom.xml") -or Test-Path (Join-Path $RepoPath "build.gradle")){ $langs += "Java" }
    if(Test-Path (Join-Path $RepoPath "composer.json")){ $langs += "PHP" }
    if(Test-Path (Join-Path $RepoPath "Gemfile")){ $langs += "Ruby" }
    return $langs
}

function Run-LanguageTasks {
    param([string]$Lang,[string]$RepoPath)
    switch($Lang){
        "Node" {
            corepack enable | Out-Null
            if(Test-Path "$RepoPath/pnpm-lock.yaml"){ Invoke-RepoCommand "pnpm i --frozen-lockfile" $RepoPath 600 | Out-Null }
            elseif(Test-Path "$RepoPath/yarn.lock"){ Invoke-RepoCommand "yarn install --frozen-lockfile" $RepoPath 600 | Out-Null }
            else{ Invoke-RepoCommand "npm ci" $RepoPath 600 | Out-Null }
            if(Test-Path "$RepoPath/.prettierrc*" ){ Invoke-RepoCommand "npx prettier -w ." $RepoPath 600 | Out-Null }
            if(Test-Path "$RepoPath/.eslintrc*" ){ Invoke-RepoCommand "npx eslint --ext .js,.jsx,.ts,.tsx ." $RepoPath 600 | Out-Null }
            if(Test-Path "$RepoPath/tsconfig.json" ){ Invoke-RepoCommand "npx tsc -p ." $RepoPath 600 | Out-Null }
            $pkg = Get-Content "$RepoPath/package.json" -Raw | ConvertFrom-Json
            if($pkg.scripts.build){ Invoke-RepoCommand "npm run -s build" $RepoPath 600 | Out-Null }
            if($pkg.scripts.test){ Invoke-RepoCommand "npm test -s" $RepoPath 600 | Out-Null }
            Invoke-RepoCommand "npx audit-ci --high --report-type summary" $RepoPath 600 | Out-Null
        }
        "Python" {
            Invoke-RepoCommand "python -m venv .venv" $RepoPath 600 | Out-Null
            Invoke-RepoCommand ".\.venv\Scripts\python -m pip install -U pip" $RepoPath 600 | Out-Null
            if(Test-Path "$RepoPath/pyproject.toml"){ Invoke-RepoCommand ".\.venv\Scripts\python -m pip install -e .[dev]" $RepoPath 600 | Out-Null }
            elseif(Get-ChildItem $RepoPath -Filter "requirements*.txt"){ Invoke-RepoCommand ".\.venv\Scripts\python -m pip install -r requirements.txt" $RepoPath 600 | Out-Null }
            Invoke-RepoCommand ".\.venv\Scripts\python -m black ." $RepoPath 600 | Out-Null
            Invoke-RepoCommand ".\.venv\Scripts\python -m ruff check ." $RepoPath 600 | Out-Null
            if(Test-Path "$RepoPath/py.typed" -or (Select-String -Path "$RepoPath/pyproject.toml" -Pattern 'mypy' -Quiet)){ Invoke-RepoCommand ".\.venv\Scripts\python -m mypy --install-types --non-interactive" $RepoPath 600 | Out-Null }
            if(Test-Path "$RepoPath/tests"){ Invoke-RepoCommand ".\.venv\Scripts\python -m pytest -q" $RepoPath 600 | Out-Null }
            Invoke-RepoCommand ".\.venv\Scripts\pip-audit" $RepoPath 600 | Out-Null
        }
        "Go" {
            Invoke-RepoCommand "go mod tidy" $RepoPath 600 | Out-Null
            Invoke-RepoCommand "gofmt -s -w ." $RepoPath 600 | Out-Null
            Invoke-RepoCommand "go vet ./..." $RepoPath 600 | Out-Null
            Invoke-RepoCommand "go test ./..." $RepoPath 600 | Out-Null
            Invoke-RepoCommand "govulncheck ./..." $RepoPath 600 | Out-Null
        }
        "Rust" {
            Invoke-RepoCommand "cargo fmt --all" $RepoPath 600 | Out-Null
            Invoke-RepoCommand "cargo clippy -- -D warnings" $RepoPath 600 | Out-Null
            Invoke-RepoCommand "cargo test" $RepoPath 600 | Out-Null
            Invoke-RepoCommand "cargo audit" $RepoPath 600 | Out-Null
        }
        "DotNet" {
            Invoke-RepoCommand "dotnet restore" $RepoPath 600 | Out-Null
            Invoke-RepoCommand "dotnet format" $RepoPath 600 | Out-Null
            Invoke-RepoCommand "dotnet build -c Release" $RepoPath 600 | Out-Null
            Invoke-RepoCommand "dotnet test -c Release" $RepoPath 600 | Out-Null
            Invoke-RepoCommand "dotnet list package --vulnerable" $RepoPath 600 | Out-Null
        }
        "Java" {
            if(Test-Path "$RepoPath/mvnw"){ Invoke-RepoCommand "./mvnw -B -DskipTests=false verify" $RepoPath 600 | Out-Null }
            elseif(Test-Path "$RepoPath/pom.xml"){ Invoke-RepoCommand "mvn -B -DskipTests=false verify" $RepoPath 600 | Out-Null }
            elseif(Test-Path "$RepoPath/gradlew"){ Invoke-RepoCommand "./gradlew --no-daemon build test" $RepoPath 600 | Out-Null }
            elseif(Test-Path "$RepoPath/build.gradle"){ Invoke-RepoCommand "gradle --no-daemon build test" $RepoPath 600 | Out-Null }
        }
        "PHP" {
            Invoke-RepoCommand "composer install --no-interaction --prefer-dist" $RepoPath 600 | Out-Null
            $cjson = Get-Content "$RepoPath/composer.json" -Raw | ConvertFrom-Json
            if($cjson.scripts.test){ Invoke-RepoCommand "composer test" $RepoPath 600 | Out-Null }
            Invoke-RepoCommand "composer audit" $RepoPath 600 | Out-Null
        }
        "Ruby" {
            Invoke-RepoCommand "bundle install" $RepoPath 600 | Out-Null
            if(Test-Path "$RepoPath/Rakefile"){ Invoke-RepoCommand "bundle exec rake test" $RepoPath 600 | Out-Null }
            elseif(Get-ChildItem $RepoPath -Filter "*_spec.rb" -Recurse){ Invoke-RepoCommand "bundle exec rspec" $RepoPath 600 | Out-Null }
            Invoke-RepoCommand "rubocop" $RepoPath 600 | Out-Null
            Invoke-RepoCommand "bundler audit" $RepoPath 600 | Out-Null
        }
    }
}

function Scaffold-Hygiene {
    param([string]$RepoPath,[string]$DefaultBranch)
    if($SetupPreCommit){ Copy-Item "$PSScriptRoot/.pre-commit-config.yaml" "$RepoPath/.pre-commit-config.yaml" -Force }
    if($SetupCI){ Copy-Item "$PSScriptRoot/.github/workflows/ci.yml" "$RepoPath/.github/workflows/ci.yml" -Force }
    if($SetupDependabot -and $UseDependabot){ Copy-Item "$PSScriptRoot/.github/dependabot.yml" "$RepoPath/.github/dependabot.yml" -Force }
    if($SetupCodeQL){
        $codeqlPath = Join-Path $RepoPath ".github/workflows/codeql.yml"
        if(-not (Test-Path $codeqlPath)){
            $codeql = @" 
name: CodeQL
on:
  push:
    branches: [$DefaultBranch]
  pull_request:
    branches: [$DefaultBranch]
jobs:
  analyze:
    uses: github/codeql-action/analyze@v3
"@
            New-Item -ItemType Directory -Path (Split-Path $codeqlPath) -Force | Out-Null
            $codeql | Set-Content $codeqlPath
        }
    }
    foreach($file in @(".editorconfig",".gitattributes",".gitignore","SECURITY.md","CONTRIBUTING.md","CODE_OF_CONDUCT.md","CODEOWNERS","LICENSE")){
        $dest = Join-Path $RepoPath $file
        if(-not (Test-Path $dest)){
            switch($file){
                ".gitignore"       { $content = "*.log`nnode_modules`n.env`n" }
                ".editorconfig"    { $content = "* =`n    end_of_line = lf`n    insert_final_newline = true`n" }
                ".gitattributes"   { $content = "* text=auto`n" }
                "SECURITY.md"      { $content = "# Security Policy`nPlease report vulnerabilities via Issues." }
                "CONTRIBUTING.md"  { $content = "# Contributing`nPull requests are welcome." }
                "CODE_OF_CONDUCT.md"{ $content = "# Code of Conduct`nBe excellent to each other." }
                "CODEOWNERS"       { $content = "$($Reviewers -join ' ')`n" }
                "LICENSE"          { $content = "MIT License`n`nCopyright (c) $(Get-Date -Format yyyy) $env:USERNAME" }
            }
            $content | Set-Content $dest
        }
    }
}

function Commit-Changes {
    param([string]$RepoPath,[string]$Message)
    Set-Location $RepoPath
    git add -A
    if($SignCommits){ git -c commit.gpgsign=true commit -m $Message }
    else{ git commit -m $Message }
}

function Process-Repo {
    param($Repo)
    $result = @{ Repo=$Repo; Status="PASS"; Report="" }
    try{
        $branch = "$BranchPrefix-$(Get-Date -Format yyyyMMdd)"
        $tmp = Join-Path ([IO.Path]::GetTempPath()) ([IO.Path]::GetRandomFileName())
        git clone "https://github.com/$Repo.git" $tmp | Out-Null
        Set-Location $tmp
        $defaultBranch = (git remote show origin | Select-String "HEAD branch" | ForEach-Object { $_.ToString().Split(":")[1].Trim() })
        git checkout -b $branch origin/$defaultBranch | Out-Null
        $langs = Detect-Languages $tmp
        if($LanguageAllowlist.Count -gt 0){ $langs = $langs | Where-Object { $LanguageAllowlist -contains $_ } }
        foreach($lang in $langs){ Run-LanguageTasks $lang $tmp }
        Scaffold-Hygiene $tmp $defaultBranch
        if(-not $DryRun){
            Commit-Changes $tmp "chore: repository health sweep"
            if($Push){ git push origin $branch --force }
            if($CreatePR){
                gh pr create -B $defaultBranch -H $branch -t "Repo health sweep $(Get-Date -Format yyyy-MM-dd)" -b "Automated sweep." --label ($Labels -join ",") --reviewer ($Reviewers -join ",") | Out-Null
            }
        }
        $reportFile = Join-Path $ReportPath ($Repo.Replace("/","-") + "-REPORT.md")
        New-Report (Split-Path $reportFile)
        "## $Repo`nLanguages: $($langs -join ', ')`nStatus: PASS" | Set-Content $reportFile
        $result.Report = $reportFile
    }
    catch{
        $result.Status = "FAIL"
        $reportFile = Join-Path $ReportPath ($Repo.Replace("/","-") + "-REPORT.md")
        New-Report (Split-Path $reportFile)
        "## $Repo`nStatus: FAIL`n``````$($_.Exception.Message)`n```" | Set-Content $reportFile
        $result.Report = $reportFile
    }
    return $result
}

Test-Prerequisites
New-Report $ReportPath
$repoList = Get-RepoList
$results = $repoList | ForEach-Object -Parallel { Process-Repo $_ } -ThrottleLimit $MaxParallel
$aggregate = Join-Path $ReportPath "SWEEP-REPORT.md"
"Repo | Status`n---- | ------" | Set-Content $aggregate
foreach($r in $results){
    "{0} | {1}" -f $r.Repo,$r.Status | Add-Content $aggregate
}
if($results.Status -contains "FAIL"){ exit 1 } else { exit 0 }
