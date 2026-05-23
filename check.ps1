$err = $null
$ast = [System.Management.Automation.Language.Parser]::ParseFile("c:\Users\HazemHamza\Downloads\remoteshell xmr miner\deploy.ps1", [ref]$null, [ref]$err)
if ($err) {
    foreach ($e in $err) {
        Write-Output "Error: $($e.Message) at line $($e.Extent.StartLineNumber)"
    }
} else {
    Write-Output "Syntax OK"
}
