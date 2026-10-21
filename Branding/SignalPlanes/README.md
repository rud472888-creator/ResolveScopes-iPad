# ResolveScopes · Signal Planes

사용자가 선택한 B 시안입니다. 세 신호층과 서로 다른 기준 단절부로 구성한 여섯 개의 사각형입니다. 상표·글꼴·외부 래스터를 복제하지 않고 제작한 벡터 도형입니다.

- 기본 색: Mint `#67D8C4` / Charcoal `#191919` (sRGB)
- 흑백 버전: `ResolveScopes-mark-black.svg`, `ResolveScopes-mark-white.svg`
- 기본 원본: `ResolveScopes-mark-mint.svg` (256×256 viewBox)
- 투명 PNG: `ResolveScopes-mark-*.png` (1024×1024)
- iPad 아이콘: `ResolveScopes-ipad-1024.png` (불투명 RGB; 모서리는 OS가 처리)
- Mac 아이콘: `ResolveScopes.icns`, `ResolveScopes.iconset/`, `ResolveScopes-mac-1024.png`
- 앱 내 최소 권장 표시:18pt. 기본 여백은 원본 캔버스 그대로 유지합니다.

Mac/iPad는 같은 심볼과 크기를 사용합니다. Mac의 기존 ICNS 형식에는 타일 바깥 투명 여백을 적용했습니다. iPad용은 전체 정사각형 배경을 사용합니다. [Apple 아이콘 리소스 안내](https://developer.apple.com/documentation/xcode/configuring-your-app-icon).

재생성 (macOS/Xcode 필요, 외부 Python 패키지 불필요):

```sh
xcrun swift script/BrandAssetExport.swift "$PWD"
iconutil -c icns Branding/SignalPlanes/ResolveScopes.iconset -o Branding/SignalPlanes/ResolveScopes.icns
```

앱 내 브랜드명은 기존 시스템 글꼴을 유지합니다. 별도 폰트 파일이나 글꼴 의존 SVG 워드마크는 포함하지 않습니다. 파일은 기술·시각 검사를 했으며 법적 상표 검색을 대신하지 않습니다.
