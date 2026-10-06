IIS-DNS-Lab-Fast - Dynamic Infrastructure Edition
=================================================

NO fixed IIS or DNS IP is hard-coded.

FIRST TIME ON THE IIS SERVER
----------------------------
1. Copy this folder to C:\IIS-DNS-Lab-Fast
2. Open PowerShell as Administrator.
3. Run:

   cd C:\IIS-DNS-Lab-Fast
   .\Setup-Server.ps1

4. Enter YOUR IIS management IP and YOUR DNS Server IP.
5. Configure the DNS Server with DNS Role + WinRM.
6. Run:

   .\Save-DNSCredential.ps1
   .\Test-DNS.ps1

7. Start the portal:

   .\Start-IIS.bat

The portal URL is built from the IIS management IP saved in lab-config.json.

FIRST TIME ON THE PHYSICAL CLIENT
---------------------------------
Copy IIS-DNS-Lab-Client to C:\IIS-DNS-Lab-Client and run as Administrator:

   .\Install-ClientAgent.ps1

The installer asks for the IIS management IP, DNS IP and management prefix used by that person's lab.

DAILY USE
---------
1. Double-click Start-IIS.bat on the IIS Server.
2. Enter the exam website values in the portal.
3. Press Ctrl+Enter.
4. The client agent opens the deployed site automatically.

Do not share:
- lab-config.json (optional to regenerate per environment)
- dns-credential.xml
- deploy-state.json
- *.bak
