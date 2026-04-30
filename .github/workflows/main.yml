name: Windows RDP (Browser Login)

on:
  workflow_dispatch:

jobs:
  build:
    runs-on: windows-latest

    steps:
      - name: Enable RDP & Firewall Rules
        run: |
          Set-ItemProperty -Path 'HKLM:\System\CurrentControlSet\Control\Terminal Server' -name "fDenyTSConnections" -Value 0
          Enable-NetFirewallRule -DisplayGroup "Remote Desktop"
          Set-ItemProperty -Path 'HKLM:\System\CurrentControlSet\Control\Terminal Server\WinStations\RDP-Tcp' -name "UserAuthentication" -Value 1

      - name: Create RDP User
        run: |
          # Hardcoded to bypass generation errors but still pass Windows complexity rules
          $Password = "RootUser123!"
          net user RDP $Password /add
          net localgroup administrators RDP /add

      - name: Install Tailscale
        run: |
          # Swapped to the .exe link because Tailscale removed the .msi direct link
          Invoke-WebRequest -Uri "https://pkgs.tailscale.com/stable/tailscale-setup-latest.exe" -OutFile "tailscale-setup.exe"
          Start-Process -FilePath "tailscale-setup.exe" -ArgumentList "/quiet" -Wait

      - name: Start Tailscale & Wait for Login
        run: |
          & "C:\Program Files\Tailscale\tailscale.exe" up --hostname=github-rdp-manual

      - name: Keep Session Alive
        run: |
          echo "RDP Session is active."
          while ($true) { Start-Sleep -Seconds 300 }
