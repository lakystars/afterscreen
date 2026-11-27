# Afterscreen Windows Sender

Windows PC 화면을 Mac **Afterscreen Receiver**(5K iMac 등)로 보내는 **Windows Sender**입니다.

## 개요

Mac **Afterscreen Sender**와 같은 프로토콜(protocol 11)로 Receiver에 연결합니다. Mac 쪽 구현(`Sender/`, `Receiver/`, `Core/`)이 정본이고, Windows는 그 동작을 C#/.NET 8 · D3D11 · Media Foundation(QSV)으로 포팅한 것입니다. 설계·포팅 메모는 [`docs/`](docs)를 봅니다.

## 목적

- Mac Sender와 **기능을 최대한 같게** Windows에서 송신한다.
- 최종 사용 형태: PC에 **가상 확장 모니터(VDD)** 를 두고, 그 화면을 iMac Receiver로 스트리밍한다(DisplayRole=`extend`).
- 기본 스트림·영상 레이어 크기(이 환경 기준): **2880×1620** HEVC Main10 하이브리드(움직임=영상, 정지=BC7 타일).

## Precondition (실행 전에)

앱만 빌드해서는 가상 모니터 경로가 준비되지 않습니다. 아래를 **사용자가 시스템 쪽에** 맞춰 둡니다.

### 1. Mac Receiver

- iMac(또는 지원 Mac)에서 **Afterscreen Receiver** 실행, 같은 LAN(또는 유선 링크)에서 Bonjour로 보여야 함.
- 페어링: 이더넷/Wi‑Fi는 화면에 뜨는 코드. Thunderbolt/USB 케이블(Mac–Mac, OS가 NIC를 띄운 경우)은 코드 없이 연결 가능.

### 2. Virtual Display Driver (MttVDD)

- **MikeTheTech Virtual Display Driver**(하드웨어 ID `MTT1337`) 설치.
- 설정 파일(일반 경로): `C:\VirtualDisplayDriver\vdd_settings.xml`
- **해상도 프로필에 2880×1620 @ 60 Hz가 있어야** 합니다. 예:

```xml
<resolution>
  <width>2880</width>
  <height>1620</height>
  <refresh_rate>60</refresh_rate>
</resolution>
```

- XML을 바꾼 뒤에는 드라이버/어댑터를 다시 로드하거나 PC를 재시작해 반영합니다.
- Afterscreen 앱은 연결 시 VDD 어댑터를 enable, 해제 시 disable 합니다(`VirtualDisplayControl`).  
  `SETDISPLAYCOUNT 0`으로 모니터를 끄지 않습니다 — **어댑터 PnP만** 다룹니다.
- 스모크: `Afterscreen.exe --vdd-smoke` (FLAG on일 때).

### 3. Windows 쪽 권장

- .NET 8 SDK, Windows 10/11 x64, **Intel QSV**(HEVC) 가능 GPU/드라이버.
- 프로세스 **per-monitor DPI aware**(앱 manifest 포함).
- Bonjour/탐색용으로 방화벽이 로컬 `_afterscreen._tcp`를 막지 않을 것.
- 표시 방법: 앱에서 **확장(extend)** + 출력 모니터가 VDD(2880×1620)인지 확인.  
  CLI 예: `$env:AFTERSCREEN_OUTPUT='2880x1620'; $env:AFTERSCREEN_CODEC='hevc'`

### 4. 알아둘 한계

- **일반 USB‑C(Billboard만 잡히는 Win↔Mac)** 로는 NIC가 없어 이 앱만으로 직결 불가. TB/USB4로 P2P NIC가 뜨거나 유선 LAN/Wi‑Fi를 씁니다.
- 강제 종료(`taskkill`) 시 VDD가 켜진 채 남을 수 있음 → 정상 Quit/Disconnect, 또는 장치 관리자에서 Virtual Display Driver disable.
- QSV 인코더를 만들고 버릴 때마다 드라이버 Working Set 잔여(~수백 MB)가 남을 수 있음(재연결 시 WS 증가).

## 빌드·실행 (요약)

```powershell
dotnet build Afterscreen.Sender.App\Afterscreen.Sender.App.csproj -c Release
dotnet test Afterscreen.Sender.Tests -c Release
# 앱
.\Afterscreen.Sender.App\bin\Release\net8.0-windows\Afterscreen.exe
# CLI
$env:AFTERSCREEN_OUTPUT='2880x1620'; $env:AFTERSCREEN_CODEC='hevc'
.\Afterscreen.Sender\bin\Release\net8.0-windows\Afterscreen.Sender.exe stream auto 0
```

프로토콜 메모는 [`docs/protocol-notes.md`](docs/protocol-notes.md), GPU→QSV zero-copy 설계는 [`docs/plan-gpu-qsv-zerocopy.md`](docs/plan-gpu-qsv-zerocopy.md).
