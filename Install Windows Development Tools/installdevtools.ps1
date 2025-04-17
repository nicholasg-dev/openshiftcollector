# Installs development tools for Linux, Kubernetes, HTML, and JavaScript development on Windows

# Ensure script is running as administrator
if (-not ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Write-Error "Please run this script as Administrator."
    exit 1
}

# Install Chocolatey if not present
if (-not (Get-Command choco -ErrorAction SilentlyContinue)) {
    Set-ExecutionPolicy Bypass -Scope Process -Force
    [System.Net.ServicePointManager]::SecurityProtocol = [System.Net.ServicePointManager]::SecurityProtocol -bor 3072
    Invoke-Expression ((New-Object System.Net.WebClient).DownloadString('https://community.chocolatey.org/install.ps1'))
}

# Refresh environment
$env:Path = [System.Environment]::GetEnvironmentVariable("Path","Machine")

# List of packages to install
$packages = @(
    # Linux tools
    "git",
    "wsl",
    "ubuntu",

    # Kubernetes tools
    "kubectl",
    "kubernetes-helm",
    "minikube",

    # Editors/IDEs
    "vscode",

    # Node.js and JavaScript tools
    "nodejs-lts",
    "yarn",

    # Browsers for web development
    "googlechrome",
    "firefox",

    # Other useful tools
    "docker-desktop",
    "postman"
)

# Install packages
foreach ($pkg in $packages) {
    choco install $pkg -y --ignore-checksums
}

# Install npm global tools for JS development
$npmGlobalTools = @(
    "typescript",
    "eslint",
    "prettier",
    "npm-check-updates"
)

foreach ($tool in $npmGlobalTools) {
    npm install -g $tool
}

Write-Host "Development tools installation complete. Please restart your computer if required."