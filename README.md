# IIS-DNS-Lab-Fast Universal Dynamic IP

Bản này giữ workflow giống bộ đang sử dụng, nhưng **không hard-code IP IIS, IP DNS hoặc tên máy DNS**.

Mỗi người dùng tự nhập IP hạ tầng của lab mình ở lần chạy đầu tiên.

## Kiến trúc

Có 3 máy:

- **IIS Server**: IP quản trị do người dùng tự chọn.
- **DNS Server**: IP do người dùng tự chọn; Computer Name tùy ý.
- **Windows Client / máy thật**: chạy Client Agent.

Ví dụ một người có thể dùng:

```text
IIS: 192.168.136.2/24
DNS: 192.168.136.3
```

người khác có thể dùng:

```text
IIS: 10.10.50.10/24
DNS: 10.10.50.20
```

Cả hai đều dùng cùng source code, không sửa `.ps1`.

---

## Cấu trúc

```text
IIS-DNS-Lab-Fast-Universal-DynamicIP
├── README.md
├── .gitignore
├── IIS-DNS-Lab-Fast
│   ├── Config.ps1
│   ├── Setup-Server.ps1
│   ├── Fast-Portal.ps1
│   ├── Operations.ps1
│   ├── Network.ps1
│   ├── index.html
│   ├── Save-DNSCredential.ps1
│   ├── Test-DNS.ps1
│   ├── Start-IIS.bat
│   ├── Client-Agent.ps1
│   └── Install-ClientAgent.ps1
└── IIS-DNS-Lab-Client
    ├── Client-Agent.ps1
    └── Install-ClientAgent.ps1
```

---

# 1. Chuẩn bị DNS Server

DNS Server có thể có **bất kỳ Computer Name nào**.

Đặt một IPv4 tĩnh phù hợp với lab của bạn, sau đó mở PowerShell **Run as Administrator**:

```powershell
Install-WindowsFeature DNS -IncludeManagementTools
Set-Service WinRM -StartupType Automatic
Start-Service WinRM
Enable-PSRemoting -Force

New-ItemProperty `
  -Path "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System" `
  -Name "LocalAccountTokenFilterPolicy" `
  -PropertyType DWord `
  -Value 1 `
  -Force

Restart-Service WinRM
```

Ghi lại IP DNS Server để nhập ở bước IIS và Client.

---

# 2. Cài trên IIS Server

Copy folder:

```text
IIS-DNS-Lab-Fast
```

vào:

```text
C:\IIS-DNS-Lab-Fast
```

Mở PowerShell **Run as Administrator**:

```powershell
cd C:\IIS-DNS-Lab-Fast
Set-ExecutionPolicy Bypass -Scope Process -Force
.\Setup-Server.ps1
```

Script sẽ hỏi một lần:

```text
IIS management IP on THIS server:
Management network prefix:
DNS Server IP:
Fast Portal TCP port: [8787]
```

Ví dụ:

```text
IIS management IP : 10.10.50.10
Prefix            : 24
DNS Server IP     : 10.10.50.20
Portal Port       : 8787
```

Cấu hình được lưu cục bộ vào:

```text
C:\IIS-DNS-Lab-Fast\lab-config.json
```

Không cần sửa source code.

Sau đó chạy:

```powershell
.\Save-DNSCredential.ps1
```

Nhập tài khoản Administrator thật của DNS Server, ví dụ:

```text
DNS01\Administrator
```

Tên máy DNS không cố định.

Kiểm tra:

```powershell
.\Test-DNS.ps1
```

Nếu hiện:

```text
DNS CHECK: READY
```

thì phần IIS → DNS đã sẵn sàng.

---

# 3. Cài Client Agent trên máy thật

Copy folder:

```text
IIS-DNS-Lab-Client
```

vào:

```text
C:\IIS-DNS-Lab-Client
```

Mở PowerShell **Run as Administrator**:

```powershell
cd C:\IIS-DNS-Lab-Client
Set-ExecutionPolicy Bypass -Scope Process -Force
.\Install-ClientAgent.ps1
```

Installer sẽ hỏi:

```text
IIS management / Portal IP:
DNS Server IP:
Management network prefix: [24]
```

Nhập **đúng các IP đã cấu hình trên lab của người đó**.

Ví dụ:

```text
IIS Portal IP     : 10.10.50.10
DNS Server IP     : 10.10.50.20
Management prefix : 24
```

Agent lưu cấu hình tại:

```text
C:\ProgramData\IIS-DNS-Lab-Fast\client-config.json
```

và tạo Scheduled Task:

```text
IIS DNS Lab Fast Client Agent
```

Kiểm tra:

```powershell
Get-ScheduledTask -TaskName "IIS DNS Lab Fast Client Agent"
```

Trạng thái mong muốn: `Running`.

---

# 4. Mỗi lần làm bài

Trên IIS Server chỉ cần double-click:

```text
C:\IIS-DNS-Lab-Fast\Start-IIS.bat
```

Nếu là lần đầu và chưa có `lab-config.json`, `Start-IIS.bat` sẽ tự mở `Setup-Server.ps1`.

Portal được mở theo IP IIS đã cấu hình, ví dụ:

```text
http://10.10.50.10:8787/
```

Không còn cố định `192.168.136.2`.

Nhập:

- Site Name
- Website IP
- Prefix
- Hostname website
- HTTP bật/tắt + port
- HTTPS bật/tắt + port
- Title
- Content

Nhấn **DEPLOY & OPEN ON CLIENT** hoặc `Ctrl + Enter`.

Hệ thống tự làm:

```text
Secondary IP
 -> IIS Site
 -> HTTP/HTTPS binding
 -> SSL certificate
 -> Firewall
 -> DNS Zone / A Record
 -> Health check
 -> Client Agent
 -> Microsoft Edge
```

---

# 5. IP website và hostname cùng hoạt động

Ví dụ đề yêu cầu:

```text
Site: thi
Website IP: 23.23.23.23
Prefix: 24
Hostname: www.hahahihi.vn
HTTPS: 443
```

Hệ thống tạo binding HTTPS dạng:

```text
23.23.23.23:443:
```

Certificate SAN chứa cả:

```text
DNS = www.hahahihi.vn
IP  = 23.23.23.23
```

Do đó có thể truy cập:

```text
https://23.23.23.23
https://www.hahahihi.vn
```

Nếu HTTPS dùng port `445`:

```text
https://23.23.23.23:445
https://www.hahahihi.vn:445
```

---

# 6. Đổi hạ tầng sang máy khác

Không sửa code.

Trên IIS mới chạy lại:

```powershell
.\Setup-Server.ps1
.\Save-DNSCredential.ps1
```

Trên máy thật mới chạy lại:

```powershell
.\Install-ClientAgent.ps1
```

và nhập IP IIS/DNS của môi trường mới.

---

# 7. GitHub / chia sẻ

Không upload các file sinh ra theo từng máy:

```text
lab-config.json
dns-credential.xml
deploy-state.json
*.bak
IIS-DNS-Sites/
```

Mỗi người tự tạo cấu hình bằng `Setup-Server.ps1` và `Save-DNSCredential.ps1`.

---

# 8. Kiểm tra kết nối

Ví dụ nếu IIS của người dùng là `10.10.50.10` và DNS là `10.10.50.20`:

Từ IIS Server:

```powershell
Test-NetConnection 10.10.50.20 -Port 5985
Test-WSMan 10.10.50.20
```

Từ máy thật sau khi Portal chạy:

```powershell
Test-NetConnection 10.10.50.10 -Port 8787
```

Thay IP bằng IP thật trong lab của người đang sử dụng.

---

## Tóm tắt cực ngắn

### DNS

Cài DNS Role + bật WinRM.

### IIS lần đầu

```powershell
.\Setup-Server.ps1
.\Save-DNSCredential.ps1
.\Test-DNS.ps1
```

### Client lần đầu

```powershell
.\Install-ClientAgent.ps1
```

### Mỗi lần làm bài

```text
Start-IIS.bat
→ nhập đề
→ Ctrl+Enter
→ DONE
```
