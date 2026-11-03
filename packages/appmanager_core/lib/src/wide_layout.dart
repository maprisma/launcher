/// The wide window's sizes (launcher.py): when the list turns into the
/// overview, how many cards, icon tiles or folders fit, and how large the
/// folder icons grow to fill the page. Widths are the card width (the
/// window's content width), heights the page height.
library;

const cardPadding = 34;
const tileWidth = 196, tileSpacing = 10, tileTextHeight = 84, maxColumns = 6;
const folderColumns = 3, folderRows = 3;
const folderIcon = 36, folderIconMax = 96;
const folderNameHeight = 6 + 18;
const folderTileWidth =
    folderColumns * (folderIcon + 14) + (folderColumns - 1) * 6 + 2 * 6 + 2 + 2 * 4;
const iconTileWidth = 132, iconMaxColumns = 12;

int _floorDiv(int a, int b) => (a / b).floor();

/// Card columns at this width; 1 means the narrow list.
int gridColumns(int cardWidth) {
  final inner = cardWidth - cardPadding;
  return _floorDiv(inner + tileSpacing, tileWidth + tileSpacing).clamp(1, maxColumns);
}

int iconTileWidthFor(int iconSize) => iconSize + 40 > iconTileWidth ? iconSize + 40 : iconTileWidth;

int iconColumns(int cardWidth, [int iconSize = 72]) {
  final inner = cardWidth - cardPadding;
  return _floorDiv(inner + tileSpacing, iconTileWidthFor(iconSize) + tileSpacing)
      .clamp(1, iconMaxColumns);
}

int folderColumnsAt(int cardWidth) {
  final inner = cardWidth - cardPadding;
  final n = _floorDiv(inner + tileSpacing, folderTileWidth + tileSpacing);
  return n < 1 ? 1 : n;
}

/// A folder's narrowest width and its height with icons of this size.
(int, int) folderTileSize(int icon) {
  final cell = icon + 14;
  final icons = folderColumns * cell + (folderColumns - 1) * 6;
  final rows = folderRows * cell + (folderRows - 1) * 6;
  return (icons + 2 * 6 + 2 + 2 * 4, rows + 2 * 10 + 2 + 4 + 6 + folderNameHeight);
}

/// Folders per row and icon size so that [count] folders fill the page; the
/// column count giving the largest icons wins. Too many: the smallest size,
/// as many per row as fit, and the page scrolls.
(int, int) folderFit(int count, int cardWidth, int height) {
  final inner = cardWidth - cardPadding;
  if (count < 1) return (folderColumnsAt(cardWidth), folderIcon);
  final (baseW, baseH) = folderTileSize(0);
  var bestColumns = 1, bestIcon = -1;
  for (var columns = 1; columns <= count; columns++) {
    final rows = (count / columns).ceil();
    final tileW = (inner - (columns - 1) * tileSpacing) / columns;
    final tileH = (height - (rows - 1) * tileSpacing) / rows;
    final a = (tileW - baseW) / folderColumns - 14;
    final b = (tileH - baseH) / folderRows - 14;
    final icon = (a < b ? a : b).truncate(); // Python int(): towards zero
    if (icon > bestIcon) {
      bestColumns = columns;
      bestIcon = icon;
    }
  }
  if (bestIcon < folderIcon) return (folderColumnsAt(cardWidth), folderIcon);
  return (bestColumns, bestIcon < folderIconMax ? bestIcon : folderIconMax);
}

/// A folder icon's drawn size: Settings › Icon size: Folders as a share of
/// the fitted size; never past its cell.
int folderAppIcon(int fitted, int percent) {
  final want = pyRound(fitted * percent / 100);
  final atLeast = want > 16 ? want : 16;
  return fitted < atLeast ? fitted : atLeast;
}

/// The height of a folder's icon area that fills the page's height.
int folderIconsHeight(int count, int columns, int icon, int height) {
  final rowsHeight = folderRows * (icon + 14) + (folderRows - 1) * 6;
  final rows = ((count < 1 ? 1 : count) / (columns < 1 ? 1 : columns)).ceil();
  final tileH = (height - (rows - 1) * tileSpacing) / rows;
  final spread = (tileH - (folderTileSize(icon).$2 - rowsHeight)).truncate();
  return spread > rowsHeight ? spread : rowsHeight;
}

/// Python's round(): halves go to the even neighbour (24.5 → 24).
int pyRound(double x) {
  final f = x.floorToDouble();
  final diff = x - f;
  if (diff > .5) return f.toInt() + 1;
  if (diff < .5) return f.toInt();
  return f.toInt().isEven ? f.toInt() : f.toInt() + 1;
}
