"""
TradingView Backtest Extractor
================================
This script extracts trade data from TradingView chart screenshots.

SETUP:
------
pip install pytesseract Pillow opencv-python pandas openpyxl

Also install Tesseract OCR:
- Windows: https://github.com/tesseract-ocr/tesseract/releases
- Mac: brew install tesseract
- Linux: sudo apt install tesseract-ocr

USAGE:
------
1. Take screenshots of your TradingView charts (with visible price levels)
2. Put them in a folder called "screenshots/"
3. Run: python tradingview_backtest_extractor.py
4. Results will be saved in "backtest_results.csv" and "backtest_results.xlsx"
"""

import os
import re
import csv
import sys
from datetime import datetime

# === Check dependencies ===
try:
    import pytesseract
    from PIL import Image
    import cv2
    import numpy as np
except ImportError:
    print("=" * 60)
    print("MISSING DEPENDENCIES! Run this command first:")
    print("")
    print("  pip install pytesseract Pillow opencv-python numpy pandas openpyxl")
    print("")
    print("Also install Tesseract OCR:")
    print("  Windows: Download from github.com/tesseract-ocr/tesseract/releases")
    print("  Mac:     brew install tesseract")
    print("  Linux:   sudo apt install tesseract-ocr")
    print("=" * 60)
    sys.exit(1)

try:
    import pandas as pd
    HAS_PANDAS = True
except ImportError:
    HAS_PANDAS = False
    print("Note: pandas not installed. Will export CSV only (no .xlsx)")


# ============================================================
# CONFIGURATION
# ============================================================

SCREENSHOTS_FOLDER = "screenshots"     # Folder with your TradingView screenshots
OUTPUT_CSV = "backtest_results.csv"    # Output CSV file
OUTPUT_XLSX = "backtest_results.xlsx"  # Output Excel file

# Adjust if Tesseract is not in PATH (Windows users)
# pytesseract.pytesseract.tesseract_cmd = r'C:\Program Files\Tesseract-OCR\tesseract.exe'


# ============================================================
# IMAGE PREPROCESSING
# ============================================================

def preprocess_image(image_path):
    """
    Preprocess TradingView screenshot for better OCR results.
    Focuses on the price axis (right side of chart).
    """
    img = cv2.imread(image_path)
    if img is None:
        print(f"  [ERROR] Cannot read image: {image_path}")
        return None

    height, width = img.shape[:2]

    # Crop right side (price axis) - usually rightmost 15% of the image
    price_axis = img[:, int(width * 0.85):]

    # Convert to grayscale
    gray = cv2.cvtColor(price_axis, cv2.COLOR_BGR2GRAY)

    # Increase contrast
    gray = cv2.convertScaleAbs(gray, alpha=1.5, beta=0)

    # Threshold to make text clearer
    _, thresh = cv2.threshold(gray, 150, 255, cv2.THRESH_BINARY_INV)

    # Invert back
    thresh = cv2.bitwise_not(thresh)

    return thresh


def preprocess_full_image(image_path):
    """
    Preprocess full image to detect trade labels (R1.1, R1.2, etc.)
    """
    img = cv2.imread(image_path)
    if img is None:
        return None

    # Convert to grayscale
    gray = cv2.cvtColor(img, cv2.COLOR_BGR2GRAY)

    # Adaptive threshold for better text detection
    thresh = cv2.adaptiveThreshold(
        gray, 255, cv2.ADAPTIVE_THRESH_GAUSSIAN_C,
        cv2.THRESH_BINARY, 11, 2
    )

    return thresh


# ============================================================
# PRICE EXTRACTION
# ============================================================

def extract_prices_from_axis(processed_image):
    """
    Extract price values from the price axis using OCR.
    """
    if processed_image is None:
        return []

    # OCR with specific config for numbers
    custom_config = r'--oem 3 --psm 6 -c tessedit_char_whitelist=0123456789.,'
    text = pytesseract.image_to_string(processed_image, config=custom_config)

    # Find all price-like patterns (e.g., 4,338.19 or 4338.19)
    prices = re.findall(r'[\d,]+\.\d{1,3}', text)

    # Clean and convert
    clean_prices = []
    for p in prices:
        try:
            clean_p = float(p.replace(',', ''))
            if clean_p > 100:  # Filter out noise (valid trading prices)
                clean_prices.append(clean_p)
        except ValueError:
            continue

    return sorted(set(clean_prices), reverse=True)


def extract_labels_from_chart(image_path):
    """
    Extract trade labels (R1.1, R1.2, R1.3, SL, Entry) from chart.
    """
    processed = preprocess_full_image(image_path)
    if processed is None:
        return {}

    # OCR full image
    text = pytesseract.image_to_string(processed)

    labels = {}

    # Look for R1.1, R1.2, R1.3, R.1.1, R.1.2, R.1.3 patterns
    r_patterns = re.findall(r'R\.?1\.?[123]', text, re.IGNORECASE)
    if r_patterns:
        labels['has_r_levels'] = True

    # Look for Buy/Sell/Bull/Bear signals
    if re.search(r'\b(sell|bear|short)\b', text, re.IGNORECASE):
        labels['direction'] = 'SELL'
    elif re.search(r'\b(buy|bull|long)\b', text, re.IGNORECASE):
        labels['direction'] = 'BUY'

    return labels


# ============================================================
# TRADE DETECTION LOGIC
# ============================================================

def detect_trade_zones(image_path):
    """
    Detect colored zones (green=TP, red=SL) to identify trade levels.
    """
    img = cv2.imread(image_path)
    if img is None:
        return {}

    hsv = cv2.cvtColor(img, cv2.COLOR_BGR2HSV)
    height, width = img.shape[:2]

    # Detect RED zones (Stop Loss areas)
    red_lower1 = np.array([0, 50, 50])
    red_upper1 = np.array([10, 255, 255])
    red_lower2 = np.array([170, 50, 50])
    red_upper2 = np.array([180, 255, 255])
    red_mask = cv2.inRange(hsv, red_lower1, red_upper1) | cv2.inRange(hsv, red_lower2, red_upper2)

    # Detect GREEN zones (Take Profit areas)
    green_lower = np.array([35, 50, 50])
    green_upper = np.array([85, 255, 255])
    green_mask = cv2.inRange(hsv, green_lower, green_upper)

    # Find vertical positions of colored zones
    zones = {
        'red_zones': [],
        'green_zones': []
    }

    # Get average Y position of red zones
    red_rows = np.where(red_mask.sum(axis=1) > width * 0.1)[0]
    if len(red_rows) > 0:
        # Cluster red zones
        zones['red_zones'] = cluster_positions(red_rows, height)

    # Get average Y position of green zones
    green_rows = np.where(green_mask.sum(axis=1) > width * 0.1)[0]
    if len(green_rows) > 0:
        zones['green_zones'] = cluster_positions(green_rows, height)

    return zones


def cluster_positions(rows, image_height, min_gap=20):
    """
    Cluster nearby rows into zones and return their center positions.
    """
    if len(rows) == 0:
        return []

    clusters = []
    current_cluster = [rows[0]]

    for i in range(1, len(rows)):
        if rows[i] - rows[i-1] <= min_gap:
            current_cluster.append(rows[i])
        else:
            clusters.append(int(np.mean(current_cluster)))
            current_cluster = [rows[i]]

    clusters.append(int(np.mean(current_cluster)))
    return clusters


def map_prices_to_levels(prices, zones, labels, image_path):
    """
    Map extracted prices to trade levels (Entry, SL, R1.1, R1.2, R1.3).
    Uses color zones and price ordering to determine levels.
    """
    if len(prices) < 4:
        print(f"  [WARNING] Only {len(prices)} prices found. Need at least 4.")
        return None

    direction = labels.get('direction', 'SELL')

    trade = {
        'direction': direction,
        'entry': None,
        'sl': None,
        'r1_1': None,
        'r1_2': None,
        'r1_3': None,
    }

    # Sort prices high to low
    sorted_prices = sorted(prices, reverse=True)

    if direction == 'SELL':
        # For SELL: SL is highest, Entry below SL, then R1.1 > R1.2 > R1.3 below entry
        trade['sl'] = sorted_prices[0]      # Highest = Stop Loss
        trade['entry'] = sorted_prices[1]    # Second highest = Entry

        # Take profits below entry
        tps = sorted_prices[2:]
        if len(tps) >= 3:
            trade['r1_1'] = tps[0]   # First TP
            trade['r1_2'] = tps[1]   # Second TP
            trade['r1_3'] = tps[2]   # Third TP
        elif len(tps) >= 2:
            trade['r1_1'] = tps[0]
            trade['r1_2'] = tps[1]
        elif len(tps) >= 1:
            trade['r1_1'] = tps[0]

    else:  # BUY
        # For BUY: SL is lowest, Entry above SL, then R1.1 < R1.2 < R1.3 above entry
        trade['sl'] = sorted_prices[-1]      # Lowest = Stop Loss
        trade['entry'] = sorted_prices[-2]   # Second lowest = Entry

        # Take profits above entry
        tps = sorted_prices[:-2]
        if len(tps) >= 3:
            trade['r1_1'] = tps[-1]   # First TP (closest to entry)
            trade['r1_2'] = tps[-2]   # Second TP
            trade['r1_3'] = tps[-3]   # Third TP
        elif len(tps) >= 2:
            trade['r1_1'] = tps[-1]
            trade['r1_2'] = tps[-2]
        elif len(tps) >= 1:
            trade['r1_1'] = tps[-1]

    return trade


# ============================================================
# MAIN PROCESSING
# ============================================================

def process_screenshot(image_path):
    """
    Process a single TradingView screenshot and extract trade data.
    """
    print(f"\n{'='*50}")
    print(f"Processing: {os.path.basename(image_path)}")
    print(f"{'='*50}")

    # Step 1: Extract prices from price axis
    print("  [1/4] Reading price axis...")
    processed_axis = preprocess_image(image_path)
    prices = extract_prices_from_axis(processed_axis)
    print(f"        Found {len(prices)} price levels: {prices[:8]}")

    # Step 2: Extract labels from chart
    print("  [2/4] Detecting labels...")
    labels = extract_labels_from_chart(image_path)
    print(f"        Direction: {labels.get('direction', 'Unknown')}")

    # Step 3: Detect color zones
    print("  [3/4] Analyzing color zones...")
    zones = detect_trade_zones(image_path)
    print(f"        Red zones: {len(zones.get('red_zones', []))}")
    print(f"        Green zones: {len(zones.get('green_zones', []))}")

    # Step 4: Map prices to trade levels
    print("  [4/4] Mapping trade levels...")
    trade = map_prices_to_levels(prices, zones, labels, image_path)

    if trade:
        # Calculate RR ratios
        if trade['entry'] and trade['sl']:
            risk = abs(trade['sl'] - trade['entry'])
            trade['risk'] = round(risk, 2)

            for level_key in ['r1_1', 'r1_2', 'r1_3']:
                if trade[level_key]:
                    reward = abs(trade['entry'] - trade[level_key])
                    trade[f'{level_key}_rr'] = round(reward / risk, 2) if risk > 0 else 0
                    trade[f'{level_key}_reward'] = round(reward, 2)

        trade['filename'] = os.path.basename(image_path)
        trade['date'] = datetime.now().strftime('%Y-%m-%d')

        print(f"\n  ✓ Trade extracted:")
        print(f"    Direction: {trade['direction']}")
        print(f"    Entry:     {trade.get('entry')}")
        print(f"    SL:        {trade.get('sl')}")
        print(f"    R1.1:      {trade.get('r1_1')} (RR: {trade.get('r1_1_rr', '-')})")
        print(f"    R1.2:      {trade.get('r1_2')} (RR: {trade.get('r1_2_rr', '-')})")
        print(f"    R1.3:      {trade.get('r1_3')} (RR: {trade.get('r1_3_rr', '-')})")

    return trade


def process_all_screenshots():
    """
    Process all screenshots in the folder and save results.
    """
    # Create screenshots folder if it doesn't exist
    if not os.path.exists(SCREENSHOTS_FOLDER):
        os.makedirs(SCREENSHOTS_FOLDER)
        print(f"\n📁 Created '{SCREENSHOTS_FOLDER}/' folder.")
        print(f"   Put your TradingView screenshots there and run again!")
        return

    # Get all image files
    valid_extensions = ('.png', '.jpg', '.jpeg', '.bmp', '.tiff')
    images = [
        os.path.join(SCREENSHOTS_FOLDER, f)
        for f in sorted(os.listdir(SCREENSHOTS_FOLDER))
        if f.lower().endswith(valid_extensions)
    ]

    if not images:
        print(f"\n❌ No images found in '{SCREENSHOTS_FOLDER}/' folder.")
        print(f"   Supported formats: {', '.join(valid_extensions)}")
        return

    print(f"\n📊 TradingView Backtest Extractor")
    print(f"   Found {len(images)} screenshot(s) to process")

    # Process each screenshot
    trades = []
    for i, image_path in enumerate(images, 1):
        trade = process_screenshot(image_path)
        if trade:
            trade['trade_number'] = i
            trades.append(trade)

    if not trades:
        print("\n❌ No trades could be extracted. Check image quality.")
        return

    # Save to CSV
    print(f"\n{'='*50}")
    print(f"💾 Saving results...")

    headers = [
        'Trade #', 'Date', 'Filename', 'Direction',
        'Entry Price', 'Stop Loss', 'R1.1', 'R1.2', 'R1.3',
        'Risk', 'R1.1 Reward', 'R1.2 Reward', 'R1.3 Reward',
        'RR 1.1', 'RR 1.2', 'RR 1.3'
    ]

    with open(OUTPUT_CSV, 'w', newline='') as f:
        writer = csv.writer(f)
        writer.writerow(headers)
        for t in trades:
            writer.writerow([
                t.get('trade_number', ''),
                t.get('date', ''),
                t.get('filename', ''),
                t.get('direction', ''),
                t.get('entry', ''),
                t.get('sl', ''),
                t.get('r1_1', ''),
                t.get('r1_2', ''),
                t.get('r1_3', ''),
                t.get('risk', ''),
                t.get('r1_1_reward', ''),
                t.get('r1_2_reward', ''),
                t.get('r1_3_reward', ''),
                t.get('r1_1_rr', ''),
                t.get('r1_2_rr', ''),
                t.get('r1_3_rr', ''),
            ])

    print(f"   ✓ CSV saved: {OUTPUT_CSV}")

    # Save to Excel if pandas available
    if HAS_PANDAS:
        df = pd.DataFrame(trades)
        df = df.rename(columns={
            'trade_number': 'Trade #',
            'date': 'Date',
            'filename': 'Filename',
            'direction': 'Direction',
            'entry': 'Entry Price',
            'sl': 'Stop Loss',
            'r1_1': 'R1.1',
            'r1_2': 'R1.2',
            'r1_3': 'R1.3',
            'risk': 'Risk',
            'r1_1_reward': 'R1.1 Reward',
            'r1_2_reward': 'R1.2 Reward',
            'r1_3_reward': 'R1.3 Reward',
            'r1_1_rr': 'RR 1.1',
            'r1_2_rr': 'RR 1.2',
            'r1_3_rr': 'RR 1.3',
        })
        # Keep only relevant columns
        keep_cols = [c for c in headers if c in df.columns]
        df = df[keep_cols] if keep_cols else df
        df.to_excel(OUTPUT_XLSX, index=False, engine='openpyxl')
        print(f"   ✓ Excel saved: {OUTPUT_XLSX}")

    print(f"\n{'='*50}")
    print(f"✅ Done! {len(trades)} trade(s) extracted successfully.")
    print(f"{'='*50}")


# ============================================================
# RUN
# ============================================================

if __name__ == "__main__":
    process_all_screenshots()
