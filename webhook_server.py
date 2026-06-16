"""
TradingView Webhook Server
============================
Receives trade alerts from TradingView and saves them to CSV/Excel.

This server listens for webhook POST requests from TradingView alerts.
Each alert contains trade data (Entry, SL, TP1, TP2, TP3) in JSON format.

SETUP:
------
pip install flask pandas openpyxl

USAGE:
------
python webhook_server.py

Then set your TradingView alert webhook URL to:
  http://YOUR_SERVER_IP:5000/webhook

For production, use ngrok or deploy to a cloud server:
  ngrok http 5000
  → Use the ngrok URL as your webhook in TradingView

EXPECTED JSON PAYLOAD FROM TRADINGVIEW:
---------------------------------------
{
    "pair": "XAUUSD",
    "timeframe": "5",
    "direction": "SELL",
    "entry": 4338.19,
    "sl": 4348.61,
    "tp1": 4331.77,
    "tp2": 4324.92,
    "tp3": 4318.81,
    "rr1": 1.1,
    "rr2": 2.2,
    "rr3": 3.3
}
"""

import os
import csv
import json
import logging
from datetime import datetime
from flask import Flask, request, jsonify

# Optional imports
try:
    import pandas as pd
    HAS_PANDAS = True
except ImportError:
    HAS_PANDAS = False

# ============================================================
# CONFIGURATION
# ============================================================

HOST = "0.0.0.0"           # Listen on all interfaces
PORT = 5000                 # Port number
OUTPUT_CSV = "trades_log.csv"
OUTPUT_XLSX = "trades_log.xlsx"
SECRET_TOKEN = os.environ.get("WEBHOOK_SECRET", "")  # Optional security token

# ============================================================
# SETUP
# ============================================================

app = Flask(__name__)

# Logging
logging.basicConfig(
    level=logging.INFO,
    format='%(asctime)s [%(levelname)s] %(message)s',
    handlers=[
        logging.FileHandler("webhook_server.log"),
        logging.StreamHandler()
    ]
)
logger = logging.getLogger(__name__)

# CSV Headers
HEADERS = [
    'Trade #', 'Date', 'Time', 'Pair', 'Timeframe', 'Direction',
    'Entry', 'Stop Loss', 'TP1 (R1.1)', 'TP2 (R1.2)', 'TP3 (R1.3)',
    'Risk', 'RR1', 'RR2', 'RR3', 'Status'
]


# ============================================================
# HELPER FUNCTIONS
# ============================================================

def get_next_trade_number():
    """Get next trade number from CSV file."""
    if not os.path.exists(OUTPUT_CSV):
        return 1
    try:
        with open(OUTPUT_CSV, 'r') as f:
            reader = csv.reader(f)
            rows = list(reader)
            if len(rows) <= 1:
                return 1
            return int(rows[-1][0]) + 1
    except (ValueError, IndexError):
        return 1


def save_trade_to_csv(trade_data):
    """Save a single trade to CSV file."""
    trade_num = get_next_trade_number()
    now = datetime.now()

    # Extract data from payload
    pair = trade_data.get('pair', 'Unknown')
    timeframe = trade_data.get('timeframe', '')
    direction = trade_data.get('direction', '').upper()
    entry = trade_data.get('entry', 0)
    sl = trade_data.get('sl', 0)
    tp1 = trade_data.get('tp1', '')
    tp2 = trade_data.get('tp2', '')
    tp3 = trade_data.get('tp3', '')

    # Calculate risk and RR if not provided
    risk = abs(float(entry) - float(sl)) if entry and sl else 0

    rr1 = trade_data.get('rr1', '')
    rr2 = trade_data.get('rr2', '')
    rr3 = trade_data.get('rr3', '')

    # Calculate RR if not provided but TP values exist
    if not rr1 and tp1 and risk > 0:
        rr1 = round(abs(float(entry) - float(tp1)) / risk, 2)
    if not rr2 and tp2 and risk > 0:
        rr2 = round(abs(float(entry) - float(tp2)) / risk, 2)
    if not rr3 and tp3 and risk > 0:
        rr3 = round(abs(float(entry) - float(tp3)) / risk, 2)

    # Build row
    row = [
        trade_num,
        now.strftime('%Y-%m-%d'),
        now.strftime('%H:%M:%S'),
        pair,
        timeframe,
        direction,
        entry,
        sl,
        tp1,
        tp2,
        tp3,
        round(risk, 2),
        rr1,
        rr2,
        rr3,
        'OPEN'
    ]

    # Write to CSV
    file_exists = os.path.exists(OUTPUT_CSV)
    with open(OUTPUT_CSV, 'a', newline='') as f:
        writer = csv.writer(f)
        if not file_exists:
            writer.writerow(HEADERS)
        writer.writerow(row)

    # Also save to Excel if pandas available
    if HAS_PANDAS and os.path.exists(OUTPUT_CSV):
        try:
            df = pd.read_csv(OUTPUT_CSV)
            df.to_excel(OUTPUT_XLSX, index=False, engine='openpyxl')
        except Exception as e:
            logger.warning(f"Excel export failed: {e}")

    logger.info(f"✓ Trade #{trade_num} saved: {direction} {pair} @ {entry}")
    return trade_num


# ============================================================
# ROUTES
# ============================================================

@app.route('/', methods=['GET'])
def home():
    """Home page - shows server status."""
    trade_count = 0
    if os.path.exists(OUTPUT_CSV):
        with open(OUTPUT_CSV, 'r') as f:
            trade_count = max(0, sum(1 for _ in f) - 1)

    return jsonify({
        "status": "running",
        "message": "TradingView Webhook Server is active",
        "trades_logged": trade_count,
        "endpoints": {
            "webhook": "POST /webhook",
            "trades": "GET /trades",
            "stats": "GET /stats"
        }
    })


@app.route('/webhook', methods=['POST'])
def webhook():
    """
    Receive webhook from TradingView.
    TradingView sends POST with the alert message as body.
    """
    # Security check (optional)
    if SECRET_TOKEN:
        token = request.headers.get('X-Webhook-Token', '')
        if token != SECRET_TOKEN:
            logger.warning(f"Unauthorized webhook attempt from {request.remote_addr}")
            return jsonify({"error": "Unauthorized"}), 401

    # Parse the incoming data
    try:
        # TradingView can send data as JSON or plain text
        if request.is_json:
            data = request.get_json()
        else:
            # Try to parse the body as JSON (TradingView sends alert message as body)
            raw_body = request.get_data(as_text=True)
            logger.info(f"Raw webhook body: {raw_body}")
            data = json.loads(raw_body)
    except (json.JSONDecodeError, Exception) as e:
        logger.error(f"Failed to parse webhook data: {e}")
        logger.error(f"Raw body: {request.get_data(as_text=True)}")
        return jsonify({"error": "Invalid JSON payload"}), 400

    # Validate required fields
    required_fields = ['entry']
    for field in required_fields:
        if field not in data:
            return jsonify({"error": f"Missing required field: {field}"}), 400

    # Save the trade
    trade_num = save_trade_to_csv(data)

    response = {
        "success": True,
        "trade_number": trade_num,
        "message": f"Trade #{trade_num} logged successfully",
        "data": data
    }

    logger.info(f"Webhook processed: Trade #{trade_num}")
    return jsonify(response), 200


@app.route('/trades', methods=['GET'])
def get_trades():
    """Get all logged trades."""
    if not os.path.exists(OUTPUT_CSV):
        return jsonify({"trades": [], "count": 0})

    trades = []
    with open(OUTPUT_CSV, 'r') as f:
        reader = csv.DictReader(f)
        for row in reader:
            trades.append(row)

    return jsonify({
        "trades": trades,
        "count": len(trades)
    })


@app.route('/trades/last', methods=['GET'])
def get_last_trade():
    """Get the last logged trade."""
    if not os.path.exists(OUTPUT_CSV):
        return jsonify({"error": "No trades logged yet"}), 404

    with open(OUTPUT_CSV, 'r') as f:
        reader = csv.DictReader(f)
        trades = list(reader)

    if not trades:
        return jsonify({"error": "No trades logged yet"}), 404

    return jsonify({"trade": trades[-1]})


@app.route('/stats', methods=['GET'])
def get_stats():
    """Get trading statistics."""
    if not os.path.exists(OUTPUT_CSV):
        return jsonify({"error": "No trades logged yet"}), 404

    with open(OUTPUT_CSV, 'r') as f:
        reader = csv.DictReader(f)
        trades = list(reader)

    total = len(trades)
    buy_trades = sum(1 for t in trades if t.get('Direction', '').upper() == 'BUY')
    sell_trades = sum(1 for t in trades if t.get('Direction', '').upper() == 'SELL')

    # Count pairs
    pairs = {}
    for t in trades:
        pair = t.get('Pair', 'Unknown')
        pairs[pair] = pairs.get(pair, 0) + 1

    return jsonify({
        "total_trades": total,
        "buy_trades": buy_trades,
        "sell_trades": sell_trades,
        "pairs": pairs,
        "last_trade_date": trades[-1].get('Date', '') if trades else ''
    })


@app.route('/webhook/test', methods=['GET', 'POST'])
def test_webhook():
    """Test endpoint - simulates a trade alert."""
    test_data = {
        "pair": "XAUUSD",
        "timeframe": "5",
        "direction": "SELL",
        "entry": 4338.19,
        "sl": 4348.61,
        "tp1": 4331.77,
        "tp2": 4324.92,
        "tp3": 4318.81
    }

    trade_num = save_trade_to_csv(test_data)

    return jsonify({
        "success": True,
        "message": f"Test trade #{trade_num} logged!",
        "data": test_data
    })


# ============================================================
# MAIN
# ============================================================

if __name__ == '__main__':
    print("\n" + "=" * 60)
    print("  📊 TradingView Webhook Server")
    print("=" * 60)
    print(f"\n  🌐 Server running on: http://localhost:{PORT}")
    print(f"  📡 Webhook endpoint:  http://localhost:{PORT}/webhook")
    print(f"  📋 View trades:       http://localhost:{PORT}/trades")
    print(f"  📊 Statistics:        http://localhost:{PORT}/stats")
    print(f"  🧪 Test endpoint:     http://localhost:{PORT}/webhook/test")
    print(f"\n  💾 Trades saved to:   {OUTPUT_CSV}")
    print(f"\n  💡 For external access, use ngrok:")
    print(f"     ngrok http {PORT}")
    print(f"     Then use the ngrok URL in TradingView alerts")
    print("\n" + "=" * 60)
    print("  Waiting for webhooks...\n")

    app.run(host=HOST, port=PORT, debug=True)
