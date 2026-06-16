# Trading Backtest Extractor - Guide

## 📁 Files Overview

| File | Description |
|------|-------------|
| `tradingview_backtest_extractor.py` | **Automatic** - Reads screenshots using OCR |
| `manual_backtest_logger.py` | **Manual** - Interactive trade logger (more reliable) |
| `backtest_template.py` | Simple template for quick single trade logging |
| `trading_backtest.csv` | Output data file (opens in Excel) |

---

## 🚀 Option 1: Automatic Screenshot Reader (OCR)

### Setup
```bash
pip install pytesseract Pillow opencv-python numpy pandas openpyxl
```

Install Tesseract OCR:
- **Windows:** Download from [github.com/tesseract-ocr/tesseract](https://github.com/tesseract-ocr/tesseract/releases)
- **Mac:** `brew install tesseract`
- **Linux:** `sudo apt install tesseract-ocr`

### Usage
1. Create a `screenshots/` folder
2. Put your TradingView chart screenshots inside
3. Run: `python tradingview_backtest_extractor.py`
4. Results saved in `backtest_results.csv` and `backtest_results.xlsx`

### Tips for Better OCR Results
- Make sure price levels are clearly visible on the right axis
- Include the R1.1, R1.2, R1.3 labels in the screenshot
- Higher resolution = better results
- Dark theme works better than light theme

---

## 🚀 Option 2: Manual Logger (Recommended for accuracy)

### Setup
```bash
pip install pandas openpyxl  # Optional, for Excel export
```

### Usage
```bash
python manual_backtest_logger.py
```

Then follow the interactive prompts:
1. Enter pair, timeframe, direction
2. Enter Entry, SL, R1.1, R1.2, R1.3 prices
3. Data auto-saved to CSV
4. Export to Excel anytime from the menu

---

## 📊 Output Format

| Column | Description |
|--------|-------------|
| Trade # | Sequential trade number |
| Date | Trade date |
| Pair | Trading pair (XAU/USD, EUR/USD, etc.) |
| Direction | BUY or SELL |
| Entry Price | Entry price |
| Stop Loss | SL price |
| R1.1 | First take profit level |
| R1.2 | Second take profit level |
| R1.3 | Third take profit level |
| Risk | Distance from Entry to SL |
| RR 1.1 | Risk:Reward ratio at R1.1 |
| RR 1.2 | Risk:Reward ratio at R1.2 |
| RR 1.3 | Risk:Reward ratio at R1.3 |
| Result | WIN/LOSS/BE/OPEN |

---

## 💡 Pro Tips

1. **For best accuracy:** Use the manual logger and read prices directly from TradingView
2. **For bulk processing:** Use the OCR extractor with high-quality screenshots
3. **CSV files** open directly in Excel, Google Sheets, or Numbers
4. **Track your progress** using the statistics feature in the manual logger
