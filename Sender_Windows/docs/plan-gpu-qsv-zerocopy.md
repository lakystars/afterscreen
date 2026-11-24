# Plan: GPU → QSV zero-copy (CPU 절감)

작성: 2026-11-24. 구현 전 현상 파악용.  
**2026-11-24 검증 반영**(리뷰 반영): 기대치·Phase A 정의·장치 분리·측정 해석을 수정함.

## 1. 목표

- **1순위는 CPU**. fps 개선은 부수 효과.
- `cpu=`는 `TotalProcessorTime / wall / ProcessorCount`로 **논리 코어 정규화**한 값이다(이 PC ≈16 코어). 1%p ≈ wall 대비 코어 합산 ~160 ms CPU/s.
- **zero-copy 단독으로 기대하는 CPU 절감**: 고정 fps에서 대략 **1.5–2.5%p** (확정적으로 사라지는 것은 주로 `cpy` ≈0.6%p; map/submit의 CPU 비중은 Phase 0에서 확정).
- 영상 off의 **4–5%**는 작업량(sent·타일·MFT 스레드)이 다른 조건이다, zero-copy만으로 맞추는 목표가 **아니다**. 4–5% 근접은 폴링·송신 등 **별도 고정비** 작업.
- UMA에서 메모리 대역·ContextLock(map)·업로드 제거 → **대역/fps/전력** 이득 가설은 유지(신뢰도 중간 이상).

## 2. 현재 경로 (코드)

```
GpuFrame (BGRA SRV)  on capture/tile D3dEncodeDevice (gpuDev)
  → GpuVideoConverter compute → structured buffer
  → CopyResource(staging) + Flush
  → Map(Read) + MemoryCopy → IMF MediaBuffer (시스템 메모리)
  → MFT ProcessInput  (QSV; DXGI manager는 EncodeServices의 *별도* D3dEncodeDevice일 수 있음)
```

- 활성 인코더: **`path=sysmem`**.
- 2880×1620 **Main10** → P010 **B=13,996,800** (~13.3 MB/frame).
- **장치 분리**: 변환은 `gpuDev`, QSV DXGI manager는 `pipeline.D3d`일 수 있음. 과거 공유 시 WS 증가로 분리한 이력(주석). zero-copy 시 (a) manager를 `gpuDev`로 통합(WS 재검증) 또는 (b) NT-handle 공유 텍스처 + mutex/fence.
- **과거 “DXGI stall” 정정**: D3D manager를 켠 뒤에도 prove는 **sysmem `MFCreateMemoryBuffer` 샘플**로 이뤄졌다. `CreateDxgiNv12Sample`은 호출처 없는 dead code(NV12 가정·P010 미지원). **DXGI 텍스처 입력은 아직 검증된 적 없음.**

## 3. 실측 (2026-11-24, App `--connect --sound`, HEVC 2880, 유선)

진단 필드 `vd[]` (`AFTERSCREEN_VIDEO_DIAG=0`이면 끔). 60 fps 구간 대표값:

| 항목 | 대략값 | 의미 |
|---|---|---|
| cpu | 10–12% | 영상 켠 상태(16코어 정규화) |
| vi / n | ~45–52 /s | 영상 프레임 제출 수 |
| nv12 (합) | 4.5–6.5 ms | convert+readback **벽시계** |
| **vd cs** | **~0.05–0.08 ms** | CPU가 compute 명령을 **제출**한 시간(GPU 실행 시간 아님) |
| **vd gpu** | **~0.07–0.10 ms** | Copy+Flush **제출** 시간 |
| **vd map** | **~2.9–4.2 ms** | Map(Read) 대기 — GPU 실행 완료가 여기에 포함 |
| **vd cpy** | **~1.7–2.3 ms** | CPU `MemoryCopy` ~13 MB |
| submit | ~3.8–4.8 ms | **벽시계** — NeedInput `Sleep(1)` 대기 포함 가능. ProcessInput CPU만으로 단정 금지 |
| MB/s | ~560–690 | n×B/s (장면·반올림으로 소폭 편차) |
| path | sysmem | DXGI **텍스처** 입력 미사용 |

해석:

1. CPU에 **확정**으로 보이는 비용은 주로 `cpy`(초당 수백 MB memcpy).
2. `map`/`submit`은 대기가 섞인 벽시계 → CPU%와 1:1 아님. Phase 0 ablation으로 상한을 잰다.
3. zero-copy 후에도 GPU 변환·동기화 비용은 남고, 자리만 QSV 쪽으로 옮겨질 수 있다.

## 4. Zero-copy가 없애려는 것

| 단계 | 지금 | zero-copy 후 |
|---|---|---|
| Map + MemoryCopy | 매 프레임 ~13 MB → CPU | 없음 |
| ProcessInput 업로드 | sysmem → QSV surface | DXGI surface 참조(이상적; 내부 복사 여부는 측정) |
| ContextLock 중 Map 대기 | 캡처와 경합 | 텍스처 UAV/RT 기록 + 짧은 sync / tracked sample |

## 5. 위험

1. Iris에서 **진짜** DXGI 텍스처 입력이 HaveOutput을 유지하는지 미검증.
2. 장치 통합 시 WS 재발 vs shared handle 복잡도.
3. NV12/P010 텍스처에 compute UAV — FL/TYPED_UAV_STORE·PlaneSlice; 실패 시 PS/RTV 또는 `ID3D11VideoProcessor`.
4. 링 텍스처 수명: `IMFTrackedSample`로 MFT 해제 확인 전 재사용 금지. stall guard 포기 시 해당 슬롯 격리.
5. 동일 장치 시 MFT가 immediate context에 끼어듦 → `ID3D11Multithread::Enter` / `LockDevice` 검토.
6. DXGI 경로에서 unfed replacement(`!useDxgi` 조건) 누락 → 시작 ~10초 영상 공백 위험.
7. 1620은 16/32 배수 아님 — Intel MFT 정렬·내부 복사 여부 확인.
8. fps가 오르면 `cpu%`가 그대로/상승할 수 있음 → **고정 fps**로도 비교.

## 6. 단계

### Phase 0 — CPU 귀속 ✅ (2026-11-24)

목표: “readback/memcpy를 없애면 줄어드는 CPU 상한”을 수치로 확정.

Ablation (`AFTERSCREEN_VIDEO_ABLATION=memcpy|convert`), App HEVC 2880, `n`(영상 제출/초)로 구간 필터:

| 모드 | 필터 | cpu(med) | map | cpy | n |
|---|---|---|---|---|---|
| baseline | n≥35 | **12.0%** | 3.95 | 2.30 | 39 |
| memcpy (MemoryCopy 생략) | n≥25 | **11.0%** | 3.48 | 0.00 | 36 |
| convert (Convert 전체 생략) | n≥10 | 10.0%* | 0 | 0 | 25* |

\* convert 런은 cap/sent가 낮아 장면이 다름 → CPU 절감으로 해석하지 않음.

**결론**
- memcpy 제거로 CPU **약 1%p** (12→11). 검증 리뷰(~0.6–1%p)와 일치.
- “zero-copy로 10→5%” 가설은 **기각**. Phase B를 **CPU 단독 이유로는 약함**.
- **Phase A는 진행**(저비용 prove). DXGI가 살면 대역·map 락·fps 가설을 실측한 뒤 B Go/No-go.
- ETW는 선택(미실시). ablation만으로 상한은 충분.

### Phase A — **실제** DXGI 텍스처 입력 prove ✅ (2026-11-24)

구현: `AFTERSCREEN_MF_FORCE_DXGI=1`이면 DXGI 시도 우선; `_dxgiManager`가 있으면 `Encode`가 **NV12/P010 DXGI texture sample**을 넣음(P010 pitch 수정). CLI `dxgi-prove`(라이브 App과 별도 프로세스).

| 케이스 | 결과 |
|---|---|
| hevc10 2880×1620 | **OK** `async\|dxgi` UsesDxgiInput=True, post 7/8 |
| hevc8 2880×1620 | **OK** dxgi, post 7/8 |
| hevc10 1280×720 | **OK** dxgi, post 8/8 |
| h264 1280×720 | **OK** dxgi, post 8/8 |

**Go:** Iris에서 **텍스처 입력 prove는 통과**.

### Phase A′ — 실스트림 DXGI soak ✅ (2026-11-24)

구현: `ConvertGpu`가 `UsesDxgiInput`이면 슬롯별 DXGI 텍스처 샘플을 만들어 `SubmitPrepared`에 넘김(링 2장). 업로드는 아직 CPU readback→staging→CopyResource(zero-copy 아님).

App `AFTERSCREEN_MF_FORCE_DXGI=1 --connect --sound`, HEVC 2880, ~3–4분:

| 필터 | cpu(med) | n | map | cpy | submit | score | ws |
|---|---|---|---|---|---|---|---|
| path=dxgi, n≥25 | **12%** | 40 | 4.57 | 2.23 | 1.9 | 97 | ~611 |

- `path=dxgi` 전 구간(재시작 후 sysmem 0). prove `async|dxgi` OK.
- CPU/cpy는 Phase 0 baseline과 동급 — 예상됨(readback·업로드 잔존).
- WS 급증 없음(~611–613 MB). score med 97 / min 82.
- 사용자 시청: **초록 없음·끊김 없음** 확인.
- **Go for B 전제**: 라이브 DXGI ProcessInput은 유지됨. 남은 것은 장치 전략 + GPU NV12 직출(map/cpy 제거).

### Phase B — GPU NV12/P010 텍스처 출력 ✅ (2026-11-24)

**장치 전략 (a)**: MF DXGI manager를 capture/tile `gpuDev`에 재바인딩(타일+QSV 동일 장치). NT-handle(b)는 보류.  
**변환**: `ID3D11VideoProcessor` BGRA→P010/NV12 (compute UAV PlaneSlice는 미사용).  
**폴백**: `AFTERSCREEN_VIDEO_ZEROCOPY=0` 또는 VP 실패 시 A′ CPU→DXGI. GpuFrame에 RT bind 필요(SRV-only는 InputView 거절).

App HEVC 2880 Main10, `path=dxgi-zc`, ~2분+:

| 필터 | cpu(med) | n | map | cpy | score | ws |
|---|---|---|---|---|---|---|
| A′ dxgi (대비) | 12% | 40 | 4.57 | 2.23 | 97 | ~611 |
| **B dxgi-zc** | **11%** | **~52** | **0** | **0** | ~97 | ~750–765 |

- map/cpy **0** 확인. nv12 벽시계 ~1 ms(이전 ~8–11). video n↑.
- CPU ~**1%p** 절감(Phase 0 상한과 일치). 4–5% 목표는 여전히 별도 고정비.
- WS A′ 대비 **+~140 MB**(초기 측정). 코드 리뷰: 장치 통합보다 **세션당 버리는 QSV create**(EncodeServices→ReplaceVideo)가 유력 → 수정: video 생성 지연·`preferDxgi` 범위 축소·Dispose 순서.

**코드 검증 (2026-11-24): 조건부 승인**
- 차단 반영: `PreferDxgiManager`≠Wanted; MacLoop만 `preferDxgi:true`; EncodeServices zc 시 인코더 미생성; pipeline을 gpuDev보다 먼저 Dispose; rebuild Wait; zc 시 GpuVideoConverter 지연 생성.
- 남음(C): rate-demo 실측, WS A/B 재측정, VP 색공간 명시(타 GPU), TrackedSample.

### Phase C — 측정·합격선 (부분 ✅ 2026-11-24)

| 지표 | A′ dxgi | B/C dxgi-zc (수정 후) |
|---|---|---|
| cpu (n≥35) | 12% | **12%** (프레임당 ms는 소폭↓: ~46→~42) |
| map / cpy | 4.3 / 2.1 | **0 / 0** |
| path | dxgi | **dxgi-zc** |
| WS 안정 | ~610 | **~585–595** (버리는 QSV 제거 후) |
| RATE_DEMO rebuild | — | 교체당 WS 급증(~+500, 드라이버 잔여); 이후 세션 바닥이 일시↑ 가능 |

- 합격: map/cpy·path·정상 WS·시청 OK. CPU%는 n↑로 상쇄되어 중앙값은 비슷 → **프레임당**으로 보면 이득.
- rate rebuild WS·TrackedSample·VP 색(타 GPU)는 잔여.

## 7. DXGI/본선 보류 시 대안

1. staging 이중 버퍼(N 복사 중 N−1 Map) → map 대기↓, 지연 +1프레임.
2. 이벤트/`Sleep(1)`·캡처 1 ms 폴링 wake 비용 절감.
3. VideoProcessor 변환 + readback 유지(중간 형태).
4. 해상도/10-bit 완화는 사용자 기준과 충돌 → 기본 수단 아님.

## 8. 진단 로그

- `vd[cs=… gpu=… map=… cpy=… n=… B=… MB/s=… path=…]` — `AFTERSCREEN_VIDEO_DIAG=0`이면 생략.
- Ablation 시 `vd`/`State`에 `abl=memcpy|convert` 표시.

## 9. 진행 상태

- [x] 현상 측정 + 초안 plan
- [x] 리뷰 반영·plan 수정
- [x] Phase 0 ablation → CPU 상한 ~1%p; B는 CPU단독 weak
- [x] Phase A — DXGI 텍스처 prove OK (hevc10-2880 포함)
- [x] Phase A′ — 라이브 FORCE_DXGI soak OK (`path=dxgi`, cpu~12%, WS 안정)
- [x] Phase B — `path=dxgi-zc` (VP→P010, map/cpy=0)
- [x] Phase C — 측정 합격(map/cpy/WS); rate-rebuild WS는 알려진 QSV 잔여
- [ ] 다음(별도): 고정비(폴링/wake/타일) — zero-copy와 무관
