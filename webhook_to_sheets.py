"""
TradingView → Google Sheets (Python Bridge)
=============================================
Alternative method: Python server that forwards trades to Google Sheets.

This is useful if you want to:
- Process/filter trades before logging
- Add custom calculations
- Use the Python webhook server AND Google Sheets together

SETUP:
------
1. Deploy the Google Apps Script (google_sheets_setup.js) as a Web App
2. Copy the Web App URL
3. Paste it below as GOOGLE_SHEETS_WEBHOOK_URL
4. Run this script alongside webhook_server.py

OR use this standalone:
- Set your TradingView webhook to this server
- This server forwards to Google Sheets automatically
"""

import os
import json
import csv
import logging
from datetime import datetime
from flask import Flask, request, jsonify

try:
    import requests
    HAS_REQUESTS = True
except ImportError:
    HAS_REQUESTS = False
    print("⚠ 'requests' not installed. Install with: pip install requests")
    print("  Google Sheets forwarding will be disabled.")

# ============================================================
# CONFIGURATION
# ============================================================

# Your Google Apps Script Web App URL (from deployment)
GOOGLE_SHEETS_WEBHOOK_URL = os.environ.get(
    "GOOGLE_SHEETS_URL",
    "https://script.google.com/macros/s/YOUR_DEPLOYMENT_ID/exec"
)

HOST = "0.0.0.0"
PORT = 5000
OUTPUT_CSV = "trades_log.csv"  # Local backup

# ============================================================
# SETUP
# ============================================================

app = Flask(__name__)

logging.basicConfig(
    level=logging.INFO,
    format='%(asctime)s [%(levelname)s] %(message)s',
    handlers=[
        logging.FileHandler("sheets_bridge.log"),
        logging.StreamHandler()
    ]
)
logger = logging.getLogger(__name__)

HEADERS = [
    'Trade #', 'Date', 'Time', 'Pair', 'Timeframe', 'Direction',
    'Entry', 'Stop Loss', 'TP1', 'TP2', 'TP3',
    'Risk', 'RR1', 'RR2', 'RR3', 'Status'
]


# ============================================================
# HELPER FUNCTIONS
# ============================================================

def get_next_trade_number():
    """Get next trade number."""
    if not os.path.exists(OUTPUT_CSV):
        return 1
    try:
        with open(OUTPUT_CSV, 'r') as f:
            rows = list(csv.reader(f))
            return int(rows[-1][0]) + 1 if len(rows) > 1 else 1
    except (ValueError, IndexError):
        return 1


def save_local_backup(data):
    """Save trade to local CSV as backup."""
    trade_num = get_next_trade_number()
    now = datetime.now()

    entry = data.get('entry', 0)
    sl = data.get('sl', 0)
    risk = abs(float(entry) - float(sl)) if entry and sl else 0

    tp1 = data.get('tp1', '')
    tp2 = data.get('tp2', '')
    tp3 = data.get('tp3', '')

    rr1 = round(abs(float(entry) - float(tp1)) / risk, 2) if risk > 0 and tp1 else ''
    rr2 = round(abs(float(entry) - float(tp2)) / risk, 2) if risk > 0 and tp2 else ''
    rr3 = round(abs(float(entry) - float(tp3)) / risk, 2) if risk > 0 and tp3 else ''

    row = [
        trade_num, now.strftime('%Y-%m-%d'), now.strftime('%H:%M:%S'),
        data.get('pair', ''), data.get('timeframe', ''),
        data.get('direction', '').upper(),
        entry, sl, tp1, tp2, tp3,
        round(risk, 2), rr1, rr2, rr3, 'OPEN'
    ]

    file_exists = os.path.exists(OUTPUT_CSV)
    with open(OUTPUT_CSV, 'a', newline='') as f:
        writer = csv.writer(f)
        if not file_exists:
            writer.writerow(HEADERS)
        writer.writerow(row)

    return trade_num


def forward_to_google_sheets(data):
    """Forward trade data to Google Sheets Web App."""
    if not HAS_REQUESTS:
        logger.warning("requests library not available - skipping Google Sheets")
        return False, "requests library not installed"

    if "YOUR_DEPLOYMENT_ID" in GOOGLE_SHEETS_WEBHOOK_URL:
        logger.warning("Google Sheets URL not configured!")
        return False, "Google Sheets URL not configured"

    try:
        response = requests.post(
            GOOGLE_SHEETS_WEBHOOK_URL,
            json=data,
            headers={"Content-Type": "application/json"},
            timeout=10
        )

        if response.status_code == 200:
            result = response.json()
            logger.info(f"✓ Forwarded to Google Sheets: {result.get('message', 'OK')}")
            return True, result.get('message', 'Success')
        else:
            logger.error(f"Google Sheets returned status {response.status_code}: {response.text}")
            return False, f"HTTP {response.status_code}"

    except requests.exceptions.Timeout:
        logger.error("Google Sheets request timed out")
        return False, "Timeout"
    except requests.exceptions.RequestException as e:
        logger.error(f"Google Sheets request failed: {e}")
        return False, str(e)


# ============================================================
# ROUTES
# ============================================================

@app.route('/', methods=['GET'])
def home():
    """Status page."""
    sheets_configured = "YOUR_DEPLOYMENT_ID" not in GOOGLE_SHEETS_WEBHOOK_URL
    return jsonify({
        "status": "running",
        "message": "TradingView → Google Sheets Bridge",
        "google_sheets_configured": sheets_configured,
        "endpoints": {
            "webhook": "POST /webhook",
            "test": "GET /webhook/test",
            "trades": "GET /trades"
        }
    })


@app.route('/webhook', methods=['POST'])
def webhook():
    """Receive TradingView webhook and forward to Google Sheets."""
    try:
        if request.is_json:
            data = request.get_json()
        else:
            raw = request.get_data(as_text=True)
            data = json.loads(raw)
    except (json.JSONDecodeError, Exception) as e:
        return jsonify({"error": f"Invalid JSON: {e}"}), 400

    logger.info(f"📥 Received: {data.get('direction', '?')} {data.get('pair', '?')} @ {data.get('entry', '?')}")

    # Save local backup
    trade_num = save_local_backup(data)
    logger.info(f"💾 Local backup: Trade #{trade_num}")

    # Forward to Google Sheets
    sheets_success, sheets_msg = forward_to_google_sheets(data)

    response = {
        "success": True,
        "trade_number": trade_num,
        "local_saved": True,
        "google_sheets": {
            "success": sheets_success,
            "message": sheets_msg
        }
    }

    return jsonify(response), 200


@app.route('/webhook/test', methods=['GET', 'POST'])
def test():
    """Test with sample trade."""
    test_data = {
        "pair": "XAUUSD",
        "timeframe": "5",
        "direction": "SELL",
        "entry": 4338.19,
        "sl": 4348.61,
        "tp1": 4331.77,
        "tp2": 4324.92,
        "tp3": 4318.81,
        "notes": "Test trade from bridge"
    }

    trade_num = save_local_backup(test_data)
    sheets_success, sheets_msg = forward_to_google_sheets(test_data)

    return jsonify({
        "success": True,
        "trade_number": trade_num,
        "google_sheets": {"success": sheets_success, "message": sheets_msg},
        "test_data": test_data
    })


@app.route('/trades', methods=['GET'])
def trades():
    """View all trades."""
    if not os.path.exists(OUTPUT_CSV):
        return jsonify({"trades": [], "count": 0})

    with open(OUTPUT_CSV, 'r') as f:
        reader = csv.DictReader(f)
        all_trades = list(reader)

    return jsonify({"trades": all_trades, "count": len(all_trades)})


# ============================================================
# MAIN
# ============================================================

if __name__ == '__main__':
    sheets_status = "✓ Configured" if "YOUR_DEPLOYMENT_ID" not in GOOGLE_SHEETS_WEBHOOK_URL else "✗ Not configured (edit GOOGLE_SHEETS_WEBHOOK_URL)"

    print("\n" + "=" * 60)
    print("  📊 TradingView → Google Sheets Bridge")
    print("=" * 60)
    print(f"\n  🌐 Server:          http://localhost:{PORT}")
    print(f"  📡 Webhook:         http://localhost:{PORT}/webhook")
    print(f"  🧪 Test:            http://localhost:{PORT}/webhook/test")
    print(f"\n  📋 Google Sheets:   {sheets_status}")
    print(f"  💾 Local backup:    {OUTPUT_CSV}")
    print(f"\n  💡 Setup Google Sheets:")
    print(f"     1. Deploy google_sheets_setup.js as Web App")
    print(f"     2. Set GOOGLE_SHEETS_URL environment variable")
    print(f"        export GOOGLE_SHEETS_URL='https://script.google.com/...'")
    print("\n" + "=" * 60 + "\n")

    app.run(host=HOST, port=PORT, debug=True)
