# ResolveScopes for iPad

Resolve Remote Monitoring 영상을 직접 수신하고 iPad에서 영상 스코프를 계산하는 앱입니다. 현재 소스 버전은 **1.24.6**입니다. Mac 앱 없이 Resolve에 직접 연결합니다.

- Waveform, RGB Parade, Vectorscope, False Color, Source 표시
- 전체 수신 픽셀을 사용하는 GPU 스코프와 False Color
- 균등 그리드 또는 큰 패널 + 아래 작은 2·3·4개, Solo·전체 화면
- False Color 그레이바 직접 터치/드래그, 10 IRE 눈금과 구간 폭 조절
- 공통 Signal Planes 앱 아이콘과 중성 회색 UI

## 빌드

macOS와 Xcode가 필요하며, 배포 대상은 iPadOS 16 이상입니다. 현재 소스는 Xcode 27.1에서 검증했습니다.

1. `iPadCompanion/ResolveScopesPad.xcodeproj`를 엽니다.
2. **ResolveScopesPad** scheme을 선택합니다.
3. 실기기에서는 Signing & Capabilities에서 본인의 Team을 선택하고, 필요하면 Bundle Identifier를 바꿉니다.
4. iPad 또는 iPad Simulator를 선택하고 Run합니다.

서명 없이 시뮬레이터용으로 컴파일하려면:

```sh
xcodebuild -project iPadCompanion/ResolveScopesPad.xcodeproj \
  -scheme ResolveScopesPad -configuration Release \
  -destination 'generic/platform=iOS Simulator' \
  -derivedDataPath .build-ipad CODE_SIGNING_ALLOWED=NO build
```

모든 프로젝트 참조와 공용 코드를 이 저장소에 포함했습니다. 비공개 Mac 저장소나 별도 서브모듈은 필요하지 않습니다. 개인 서명 Team, 인증서, 프로비저닝 프로필과 로컬 실영상 자료는 포함하지 않습니다.

## Resolve 연결

Resolve에서 Remote Monitoring을 시작하고 같은 로컬 네트워크의 iPad에 Mac 주소를 입력합니다. 앱에서 연결한 뒤 Resolve에서 **ResolveScopes iPad** 요청을 Accept하세요. iPad의 로컬 네트워크 접근도 허용해야 합니다. Resolve 버전·에디션의 Remote Monitoring 지원이 필요합니다. 오디오는 지원하지 않습니다.

## 구조와 검증

`iPadCompanion/ResolveScopesPad/NativeRemote/`는 네이티브 수신·디코드 경로와 JavaScript 제어 협상, `Sources/ScopeCore/`는 공용 연산, `Sources/ResolveScopes/Support/`의 두 파일은 공용 GPU 래스터·오버레이입니다. 후자는 공용 파일의 원래 경로이며 Mac 앱 자체는 포함하지 않습니다.

```sh
./script/test_ipad_layout.sh
./script/test_native_media.sh
./script/test_native_video.sh
./script/test_local_scope_analyzer.sh
./iPadCompanion/ResolveScopesPad/NativeRemote/Tests/run-session-test.sh
```

테스트는 macOS/Xcode에서 실행합니다. 영상 파이프라인 테스트의 합성 HEVC 생성에는 `ffmpeg`가 필요합니다. 실제 Resolve 재생, LAN 품질과 전체 송신→화면 지연은 별도 실기기 검증이 필요합니다. 원본 Float 입력과 디코드된 모니터링 영상의 측정 동등성을 보장하지 않습니다.

## 로고와 라이선스

[Signal Planes 원본](Branding/SignalPlanes/README.md)과 [서드파티 고지](THIRD_PARTY_NOTICES.md)를 포함합니다. 원본 앱 소스에 별도 오픈소스 라이선스를 지정하지 않았습니다. 포함된 서드파티 구성 요소에는 각각의 라이선스가 적용됩니다.
