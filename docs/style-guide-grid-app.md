# Grid — Style Guide

> Bản tổng hợp toàn bộ ngôn ngữ thiết kế (design system) đang dùng trong app
> Grid, đủ chi tiết để **một app khác dựng lại được đúng cái nhìn và cảm giác
> này**. Prose bằng tiếng Việt; token/hex/tên code giữ nguyên tiếng Anh để copy
> thẳng vào codebase.
>
> Nguồn sự thật trong repo: [`lib/shared/theme/app_theme.dart`](../lib/shared/theme/app_theme.dart)
> (mọi token) và [`lib/shared/widgets/`](../lib/shared/widgets/) (component).
> File này là bản giải thích + bảng tra; khi lệch nhau, **code là chuẩn**.

---

## 0. Triết lý — "Codex-like macOS desktop"

App này là **desktop app** (macOS/Linux/Windows) cho người dùng **không rành kỹ
thuật**. Toàn bộ style xoay quanh một câu: *bình tĩnh, phẳng, sạch, giống một app
macOS bản địa (kiểu Codex), không giống một trang web hay một app điện thoại phóng to.*

Nguyên tắc gốc (giữ nguyên khi port sang app khác):

- **Gần như không viền (borderless).** Phân tách bằng **shadow mềm** và **hairline
  1px**, không phải bằng đường kẻ đậm hay ô khung.
- **Bề mặt "liquid glass" sáng, thoáng:** trắng / xám rất nhạt, nhiều khoảng thở.
- **Tương phản vừa phải.** Tránh khối đậm đặc, viền gắt, shadow lem.
- **Bo góc theo thang macOS** (nút ~8, card ~12, menu ~6) — *không* bo mạnh kiểu iOS/web.
- **Chuyển động là để liền mạch, không phải trang trí.** ~130ms, `easeOut`.
- **Copy là một phần của chất lượng.** Đây là sản phẩm cho người thường, không phải
  dev tool — chữ phải người-đọc-hiểu (xem §10).
- **Sáng & tối luôn song hành.** Mọi token có cả hai giá trị; không hardcode màu.

Tham chiếu ngắn gốc: [`.codex/notes/grid-codex-style.md`](../.codex/notes/grid-codex-style.md).

---

## 1. Hệ thống theme (nền tảng của mọi token)

App **không** đọc brightness trực tiếp từ OS. Có **một biến toàn cục duy nhất**
`AppTheme.brightness` (light/dark) mà tất cả color token resolve theo. Một widget
đồng bộ nó từ `Theme.of(context).brightness` (giá trị Material thật sự render sau
khi áp `ThemeMode.system`), nên token luôn khớp cái framework vẽ ra.

Cơ chế cần bê nguyên khi tái dựng:

- **Token là getter, không phải const.** `AppPalette.windowBg` là một getter switch
  theo brightness → call site không cần biết đang sáng hay tối.
  ```dart
  static Color get windowBg =>
      AppTheme.pick(const Color(0xFFFFFFFF), const Color(0xFF0A0A0A));
  //  AppTheme.pick(giá_trị_light, giá_trị_dark)
  ```
- **`AppTheme.watch(context)`** phải được gọi ở đầu `build()` của mọi widget
  **`const`** đọc token (sidebar, card, pill…). Vì `const` child không rebuild khi
  parent rebuild, nếu không watch nó sẽ kẹt ở palette lúc dựng lần đầu (chip tối nằm
  trên nền sáng). Cơ chế: `InheritedNotifier` (`BrightnessScope`) mark dirty trực
  tiếp, xuyên qua mọi ranh giới `const`.
- **`AppTheme.as(other, read)`** đọc token ở brightness *khác* (dùng cho ô preview
  theme): swap → đọc → trả lại trong `finally`, và swap "muted" để không bắn rebuild.

> Quy tắc vàng cho app khác: **đừng rải `Theme.of(context).brightness` khắp nơi rồi
> if/else.** Một global + getter token + một `watch()` cho widget const. Đổi một số
> ở token, không đổi ở call site.

---

## 2. Bảng màu (`AppPalette`)

Light = **giấy trắng ấm + mực gần đen**. Dark = **than chì sâu + mực trắng ngà**.
Tất cả tập trung ở `AppPalette` — không nơi nào gõ lại hex.

| Token | Light | Dark | Dùng cho |
|---|---|---|---|
| `windowBg` | `#FFFFFF` | `#0A0A0A` | Vùng nội dung / khung hội thoại |
| `panelBg` | `#F9F9F8` | `#141414` | Cột sidebar |
| `cardBg` | `#F3F3F2` | `#1E1E1E` | Fill input, card yên tĩnh |
| `cardBgHover` | `#ECECEA` | `#252525` | Trạng thái hover của trên |
| `divider` | `#0F000000` (mờ) | `#14FFFFFF` (mờ) | Hairline phân tách 1px |
| `accent` | `#2F5BEA` | `#2F5BEA` | **Action chính** (fill nền, chữ trắng) — cố định 2 theme |
| `accentOnSurface` | `#2F5BEA` | `#6E8BFF` | Accent làm **dấu trên bề mặt** (icon row selected) |
| `accentMuted` | `#3550C8` | `#4E6BF0` | Fill avatar (chữ trắng trên đó) |
| `teal` | `#0F766E` | `#2DD4BF` | Badge "Owner" |
| `online` | `#15803D` | `#3FB950` | Dot "connected" (xanh lá) |
| `warn` | `#B45309` | `#FFB020` | Sắp hết hạn / cảnh báo |
| `offline` | `#A3A29C` | `#6E6E6E` | Dot xám |
| `brandBolt` | `#C98A00` | `#E0A93B` | ⚡ thương hiệu Grid (live) |
| `textPrimary` | `#1A1A18` | `#F5F5F5` | Chữ chính |
| `textSecondary` | `#62615B` | `#A8A8A2` | Chữ phụ |
| `textFaint` | `#8E8D86` | `#6E6E68` | Chữ mờ / caption / label section |

**Bài học quan trọng** (đừng "sửa" lại): `accent` phải tách khỏi `accentOnSurface`
ở dark. `accent` là fill dưới chữ trắng ở ~100 chỗ (trắng trên nó = 5.5:1). Nhưng
`#2F5BEA` làm **icon** trên một row dark (compos ra ~#2A2A2A) chỉ đạt 2.6:1 < 3.0
(WCAG 1.4.11). Nên icon-trên-bề-mặt dùng bản sáng hơn `#6E8BFF` (4.65:1). Không gộp
hai token: sáng `accent` lên sẽ tụt chữ trắng của nút xuống ~3.1:1.

---

## 3. Bề mặt & độ nổi (surface & elevation)

Chia 4 nhóm token, mỗi nhóm một vai trò — **đừng trộn**.

### 3.1 `AppSurface` — lớp chrome (sidebar row, well recessed)
Overlay đen (trên nền sáng) ↔ trắng (trên nền tối) để hover/selected thấy được ở cả hai:

| Token | Light | Dark | Vai trò |
|---|---|---|---|
| `selectedFill` | `#0D000000` | `#14FFFFFF` | Row sidebar **đang chọn** |
| `hoverFill` | `#07000000` | `#0DFFFFFF` | Row **hover** (nhạt hơn selected — hover không được trông như selected) |
| `accentWash` | `#142F5BEA` | `#242F5BEA` | Rửa nhẹ accent dưới action chính ("New chat"), chưa cứng thành nút |
| `accentWashHover` | `#1F2F5BEA` | `#332F5BEA` | Bản đậm hơn khi hover action đó |
| `recess` | `#08000000` | `#0FFFFFFF` | Giếng lõm trong panel (cột list) |
| `recessHover` | `#12000000` | `#1AFFFFFF` | Giếng lõm khi hover (pill account) |
| `shadow` | 2 lớp (xem code) | đậm hơn | Drop shadow nâng bề mặt nổi (composer) |
| `composerShadow` | 2 lớp rộng+thấp | đậm hơn | Lift riêng cho ô composer (float rõ trên transcript) |

### 3.2 `AppGlass` — chrome mờ đặt trên nền blur (sidebar, top bar, pill, menu)
| Token | Light | Dark | Vai trò |
|---|---|---|---|
| `sidebarFill` | `#F7F9F9F8` (gần đục) | `#F01A1A1A` | Nền rail |
| `surfaceFill` | `#FFFFFF` | `#202020` | Pill/menu (trắng đặc, mềm nhờ rim+shadow) |
| `surfaceHoverFill` | `#F7F7F6` | `#272727` | Hover của trên |
| `hair` | `#14000000` | `#1FFFFFFF` | Rim hairline |
| `lift` | `#2E000000` | `#2EFFFFFF` | Rim rõ hơn cho bề mặt cần "nổi" (composer) |
| `bubbleFill` | `#F3F3F1` | `#242424` | Bong bóng tin nhắn user |
| `shadow` / `cardShadow` | mềm | đậm hơn | Lift cho pill/menu nổi |

### 3.3 `AppCard` — công thức card nội dung (áp qua `GlassCard`)
- Bề mặt: `base` (`#FFFFFF` / `#1E1E1E`), tile lõm: `inset` (`#F7F7F5` / `#181818`).
- Tint accent (dùng tiết chế): `tint10` / `tint18` / `tint25`.
- **Bo góc:** `radius = 12` (card), `insetRadius = 8` (tile trong card).
- Shadow: `shadow` (ambient mềm) và `heroShadow` (card tiêu điểm, mạnh hơn + quầng accent).

### 3.4 Nguyên tắc chọn nhóm
```
Chrome (rail/topbar/pill/menu)         → AppSurface / AppGlass
Card nội dung (chi tiết grid/engine)   → AppCard  (qua GlassCard)
Input yên tĩnh                         → AppPalette.cardBg
```
Độ sâu **luôn** đến từ *hairline rim + soft shadow*, không bao giờ từ viền đậm.

---

## 4. Kiểu chữ (`AppFont` + text theme)

### 4.1 Hai font stack và LUẬT chọn
> **Mono chỉ cho chuỗi người dùng *copy*, không phải chuỗi họ *đọc*.**

| Stack | Giá trị | Dùng cho |
|---|---|---|
| `AppFont.sans` | `.AppleSystemUIFont` (fallback: SF Pro Text, Helvetica Neue, Arial) | Mọi văn xuôi: heading, subtitle, tên |
| `AppFont.mono` | `.AppleSystemUIFontMonospaced` (fallback: Menlo, Monaco, Courier New) | model id, endpoint, token, code — thứ cần phân biệt `l/1/I`, `0/O` |

Cạm bẫy: chuỗi `'SF Mono'` **không** resolve (CoreText trả nil → rớt về Menlo âm
thầm). Chỉ tên nội bộ `.AppleSystemUIFontMonospaced` mới lấy đúng SF Mono. **Số** thì
KHÔNG dùng mono — dùng `AppFont.tabularFigures` (`FontFeature.tabularFigures()`) trên
stack sans để chữ số không nhảy khi giá trị đổi.

### 4.2 Thang text theme (light: primary `#1A1A18`, secondary `#62615B`)
Base: system font, `height: 1.34`, `letterSpacing: 0`, `w400`. Heading/label = `w600`.

| Style | Size | Weight | | Style | Size | Weight |
|---|---|---|---|---|---|---|
| displayLarge | 57 | 600 | | titleSmall | 14.5 | 600 |
| displayMedium | 45 | 600 | | bodyLarge | 16.5 | 400 |
| displaySmall | 36 | 600 | | bodyMedium | 15 | 400 |
| headlineLarge | 32 | 600 | | bodySmall | 13.5 | 400 (secondary) |
| headlineMedium | 29 | 600 | | labelLarge | 14.5 | 600 |
| headlineSmall | 25 | 600 | | labelMedium | 13 | 600 |
| titleLarge | 22 | 600 | | labelSmall | 12 | 600 |
| titleMedium | 17 | 600 | | | | |

Tiêu đề section dùng `headlineSmall`; subtitle dùng `bodyMedium` màu `onSurfaceVariant`.

---

## 5. Kích thước control (`AppControl`) — "một bộ số cho mọi nút"

macOS control = nhỏ gọn, hơi vuông, yên tĩnh: label **13pt semibold** trong capsule
~32px, bo nhỏ. **Đổi số ở đây, không đổi ở call site.**

| Token | Giá trị | Ý nghĩa |
|---|---|---|
| `height` | **32** | Chiều cao control chuẩn |
| `heightSmall` | 28 | Control gọn (action inline trong row/header card) |
| `heightField` | 36 | Ô search đầu list — cao hơn nút vì để *gõ*, không phải để *bấm* |
| `radius` | **8** | Bo góc nút (Apple: bo nhẹ, KHÔNG stadium/pill) |
| `menuRadius` | **6** | Bo menu/popover — chặt hơn nút |
| `fontSize` | **13** | Label control |
| `fontWeight` | `w600` | |
| `iconSize` | 16 | Glyph trong nút (ngồi trên cap height của label 13pt) |
| `iconSizeChip` | 13 | Glyph trên chip (label 11pt) |
| `padding` | `horizontal: 14` | Đệm ngang nút |
| `paddingSmall` | `horizontal: 10` | Nút gọn |
| `paddingSmallIcon` | `left: 12, right: 10` | Nút `.icon` gọn (lệch trái bù cho glyph) |

**LUẬT tối quan trọng:** mọi `FilledButton/OutlinedButton/TextButton` phải đặt
`tapTargetSize: MaterialTapTargetSize.shrinkWrap`. Material mặc định pad ra hộp 48px
touch → nút 32px trôi lơ lửng trong hộp 48, phá vỡ mọi hàng nó nằm. (Đã set sẵn trong
`filledButtonTheme/outlinedButtonTheme/textButtonTheme` — nhưng nếu tự styleFrom thì
phải nhớ.)

Bo góc theo thang macOS (đừng bo mạnh hơn): **nút 8 · card 12 · inset 8 · menu 6 ·
dialog 12 (=card) · snackbar 13 · toast 15 · pill toolbar 11**.

---

## 6. Chuyển động (`AppMotion`)

| Token | Giá trị | Dùng cho |
|---|---|---|
| `hover` | **130ms** | Bề mặt phản hồi con trỏ (fill row hover, chip ấm lên) |
| `swap` | 160ms | Nội dung thay tại chỗ (list đổi sang model của grid khác) |
| `curve` | `Curves.easeOut` | Curve của app — nhanh lúc đầu, dịu lúc cuối |

Motion = **liền mạch, không trang trí**: nó nói "thứ bạn đang nhìn vẫn là thứ lúc nãy".
Dài đến mức *nhận ra là animation* thì đã quá dài cho một hover. Luôn tôn trọng
**Reduce Motion** (`MediaQuery.disableAnimations`) → tắt animation, hiện trạng thái tĩnh.

---

## 7. Khoảng cách (spacing)

App không có token spacing riêng — dùng thang lặp lại nhất quán qua `SizedBox`/`EdgeInsets`:

| Bối cảnh | Giá trị |
|---|---|
| Padding một section (`SectionScaffold`) | **24** mọi phía |
| Khoảng title → divider → body | 16 · divider 1 · 16 |
| Title → subtitle | 4 |
| Gap dày trong card / giữa nhóm | 12–18 |
| Gap thường (label → control, icon → text) | 8 |
| Gap khít (value → label phụ) | 2–6 |
| Padding trong row card (MetaRow / AddressRow) | `horizontal: 14`, `vertical: 10–11` |
| Divider trong card | `Divider(height: 1, indent: 14, endIndent: 14)` |

Quy ước: comment *trên* code giải thích *tại sao*; **không** trailing comment. Line ≤ 80.

---

## 8. Thư viện component dùng chung (`lib/shared/widgets/`)

Trước khi dựng widget mới, **tái dùng** cái đã có. Danh mục:

### 8.1 Nút
- **`FilledButton`** = action chính: capsule accent đặc, chữ trắng.
- **`OutlinedButton`** = action phụ: chỉ hairline rim, không fill (kiểu "bordered" của Apple).
- **`TextButton`** = action bậc ba: chỉ chữ (lối ra yên tĩnh khỏi dialog).
- Cả ba đã themed sẵn (height 32, radius 8, 13pt w600, shrinkWrap). Chỉ styleFrom khi cần lệch.

### 8.2 `PillChoice` — segmented pill cho toolbar
Height **34**, radius **11**, 13.5pt w600. Chọn = fill `accent` + chữ trắng + `cardShadow`;
không chọn = `surfaceFill` + `textSecondary`. **Một hàng nút/pill/search phải đọc như
MỘT thanh:** cùng chiều cao 34 suốt thanh. Đừng tự chế pill — dùng lại `PillChoice`.

### 8.3 `GlassCard` — card nội dung (3 style)
```dart
GlassCardStyle.card   // card chuẩn: trắng, hairline rim, lift mềm
GlassCardStyle.hero   // card tiêu điểm: accent wash + rim + heroShadow, dẫn dắt màn hình
GlassCardStyle.inset  // giếng lõm bên trong card (list tile, log panel) — không wash/glow
```
Chi tiết chất "glass": wash gradient chéo mờ dần, quầng aura accent góc trên-phải,
hairline specular dọc mép trên. Chỉ **một** card tiêu điểm mỗi màn hình được mặc accent.

### 8.4 `SectionScaffold` — khung mỗi màn hình nav
`Padding(24)` → `Text(title, headlineSmall)` → subtitle (bodyMedium, onSurfaceVariant)
→ `Divider(1)` → body `Expanded`. Mọi section view dùng chung để lề & tiêu đề đồng nhất.

### 8.5 Chi tiết pane — `DetailSection` / `MetaRow` / `AddressRow` / `BadgePill`
- `DetailSection(title, children, trailing?)`: heading **IN HOA 11pt, letterSpacing 0.6,
  `textFaint`** + một `GlassCard` chứa các row phân tách bằng divider indent 14.
- `MetaRow(label → value)`: label `textSecondary` trái, value `textPrimary` phải.
- `AddressRow(label, value)`: value **mono** (URL/ID để copy) + `CopyIconButton` ở góc.
- `BadgePill(label, color)`: pill bo 6, fill `color@16%`, border `color@45%`, chữ `color` w600.
  Vai/quyền dùng đúng token: Owner = `teal`, Public = `accent`.

### 8.6 `StatusDot` — chấm trạng thái
Chấm tròn 9px + glow mềm (`color@50%`, blur 5). `pulsing: true` → quầng thở 1600ms cho
trạng thái "live". Màu lấy từ palette: `online` / `offline` / `warn`. Tôn trọng Reduce Motion.

### 8.7 `EmptyState` — trạng thái rỗng
`icon + title + message? + action?`. **Hai kiểu:** *chưa có gì* → kèm `action` tạo cái đầu
tiên; *không khớp filter* → `EmptyState.noMatches` (không action, fix bằng đổi query).
`compact` cho empty trong card/cột hẹp.

### 8.8 `LabeledField` / `FieldLabel` — form
Label **đứng yên phía trên** control (macOS không float label vào trong như Material).
Field: capsule mềm không viền, fill `cardBg`, bo 12, chỉ hiện hairline accent 1.5 khi focus.
`labeledFieldDecoration(hint)` để tái dùng cho `TextField` tự dựng (multiline).

### 8.9 `Toast` — thông báo (có phân cấp)
Một host duy nhất (`ToastScope`), gọi `ToastScope.show(context, spec)` từ bất kỳ đâu —
**sống sót qua `await` và sau `Navigator.pop`**. Banner top-center kiểu macOS, glass surface,
chip severity, action, vuốt lên để đóng. Severity quyết định icon/màu/thời lượng:

| Severity | Màu | Icon | Duration |
|---|---|---|---|
| `info` | `accent` | info_outline | 4s |
| `success` | `online` | check_circle | 4s |
| `warning` | `warn` | warning_amber | 5s |
| `error` | đỏ `#B3261E`/`#F2544B` | error_outline | 6s |

Tiện ích: `ToastScope.showResult(error:, success:)` — error≠null → error, ngược lại success.
`copyToClipboard(context, text)` copy + toast "Copied" 1s.

### 8.10 Code — `CodeBlock` / `GuideLabel` / `CopyIconButton` / `CopyButton`
`CodeBlock`: nền `windowBg`, viền `divider`, bo 8, chữ **mono** selectable + nút copy góc.
`CopyIconButton` (thứ cấp, góc) vs `CopyButton` (tonal accent, khi copy là action chính).

### 8.11 `SidebarItem` — một dòng rail
Công thức row duy nhất của sidebar (nav, "New chat", hội thoại đã lưu) → cùng padding/hover.
Icon mang accent khi row nổi bật (selected hoặc `emphasized`). `trailing` hiện khi hover
(nút xoá). Bo 8. Gọi `AppTheme.watch` vì rail là `const`.

### 8.12 Token riêng theo feature (mẫu `OverlordTokens`)
Khi một feature có "look" riêng (vd dashboard telemetry: mono, teal "live", màu theo tải),
gom token đó vào **một file scoped cho feature** — nhưng **surface vẫn lấy từ `AppPalette`**
để feature ngồi phẳng với phần còn lại. Đừng rải hằng số màu trong widget.

---

## 9. Bố cục & điều hướng

- **Sidebar (daily rail) là để *làm*, không phải để *cấu hình*.** Nav công việc hằng ngày
  (Chat/Playground…) ở rail.
- **Màn hình setup/plumbing (Grids / This computer / Telegram / How to use) nằm sau
  **Settings** (`SettingsPane`), full-screen:** nav list trái, màn hình phải, "Back to app"
  ở header. Cửa sổ hẹp (<1000px) → nav thu về icon + tooltip.
- **Top bar seamless:** cao 46px, **không fill/border/blur** — chỉ là hàng pill float trên
  pane + drag handle cửa sổ (`DragToMoveArea`). Pill nào rỗng thì unmount, không để capsule trơ.
- **Một hàng sáng tại một thời điểm:** highlight = "đây là màn hình bạn đang ở". Row chat có
  thể vẫn active trong state nhưng **không được trông như selected** khi đang mở section khác.
- Cửa sổ desktop co giãn → **không được overflow**: `Expanded`/`Flexible`/`Wrap` trong Row/Column
  (đừng trộn `Flexible` và `Expanded` trong cùng một cái); `LayoutBuilder`/`MediaQuery` cho
  quyết định responsive. List dài luôn `ListView.builder`/`SliverList`, không map `Column`.

---

## 10. Copy & UX (đây là sản phẩm, không phải dev tool)

- **Ngôn ngữ đời thường.** Tránh jargon (node, GGUF, llama.cpp, provider/consumer, scope,
  base URL) trong copy chính — hoặc giải thích tại chỗ.
- **Mỗi trạng thái màn hình xử lý đủ empty / loading / error**, và mỗi cái **actionable**
  (một nút hoặc một câu "làm gì tiếp").
- **Sau mỗi action, phản hồi bằng ngôn ngữ người:** success / failure / progress + bước kế.
- **Nhãn trung thực.** Không bao giờ hiện "Connected" khi chưa, hay "Start engine" khi nó không
  start. **Một từ cho một khái niệm** xuyên suốt app (đừng lẫn engine/provider/Sharing).
- Lỗi kỹ thuật (stderr CLI) → map sang câu thân thiện ở UI chính; giữ raw cho Debug/command log.
- **Không có UI test** bắt lỗi copy → tự soi lại copy trên mọi diff UI.

---

## 11. Khả năng tiếp cận (accessibility)

- **Tương phản** ≥ 4.5:1 chữ thường (≥ 3:1 chữ lớn/đậm ≥18pt) trên nền — một lý do nữa để
  dùng màu themed, không hardcode. (Xem case `accentOnSurface` ở §2.)
- **Text scaling động:** vẫn dùng được khi OS phóng chữ — đừng hardcode height/box cắt chữ scaled.
- **`Semantics`** cho control không hiển nhiên; **`tooltip`** cho nút chỉ-icon.
- Tôn trọng **Reduce Motion** (StatusDot, Toast, mọi animation).
- Không dùng ALL-CAPS cho văn bản dài (chỉ cho micro-label như heading section IN HOA 11pt).

---

## 12. Kiến trúc & state (nền để style bám vào)

- **Feature-first:** `lib/features/<feature>/{logic,presentation}`. Cross-cutting ở
  `lib/infrastructure`, `lib/shared`, `lib/core`.
- **Hướng phụ thuộc:** presentation → logic → infrastructure. Không bao giờ ngược lại.
  Presentation **không** đụng CLI/filesystem trực tiếp — qua provider/controller.
- **State = Riverpod.** Đọc reactive bằng `ref.watch`; action bằng
  `ref.read(xController.notifier).doThing()`. Ưu tiên provider/selector hẹp thay vì watch cả object.
- **Không "boolean soup":** model state controller bằng `sealed class` + `switch` vét cạn
  (vd `ProviderRunState`, `ModelPullState`).
- **Không side effect trong `build()`** hay trong updater của notifier — dời ra
  `addPostFrameCallback`. Giải phóng tài nguyên trong `ref.onDispose`/`dispose()`.

---

## 13. Definition of done (tự soi diff trước khi nói "xong")

- `flutter analyze lib test` → **0 issue**. `dart format` 80-col.
- **Tái dùng trước khi viết:** gọi helper/const có sẵn (`AppPalette`, `PillChoice`,
  `GlassCard`, `DetailSection`, `EmptyState`…) thay vì gõ lại literal / viết lại body.
  Lặp 2+ lần → tách ra.
- Widget nhỏ, một nhiệm vụ; tách `build()` lớn thành các `_SubWidget` **private** (không phải
  method trả Widget); file ~200 dòng.
- **Màu themed** (không hardcode), **sealed-state vét cạn**, **copy trung thực/đời thường**.
- Không dead/commented-out code, không nhánh always-false — xoá, đừng chôn sau comment.
- Rủi ro thật thì **nêu to** (`TODO(BE)`/ghi chú rõ), không giấu.
- Chỉ test **logic** (pure function, controller, service) — **không** viết widget/UI test.

---

### Checklist rút gọn để "mặc" style này lên app khác
1. Dựng `AppTheme` (global brightness + `pick/watch/as`) và `BrightnessScope`.
2. Copy nguyên 4 nhóm token: `AppPalette`, `AppSurface`, `AppGlass`, `AppCard`.
3. Copy `AppControl`, `AppMotion`, `AppFont`; build `ThemeData` từ **một** hàm cho cả 2 brightness.
4. Đặt nút về 32/8/13pt-w600 + `shrinkWrap`; input label-trên, focus ring accent 1.5.
5. Bê component chung: `GlassCard`, `PillChoice`, `SectionScaffold`, `DetailSection`,
   `StatusDot`, `EmptyState`, `LabeledField`, `Toast`.
6. Bố cục: rail-để-làm + Settings-full-screen-để-cấu-hình, top bar seamless, một-hàng-sáng.
7. Soi copy + accessibility + DoD trên mọi diff.
