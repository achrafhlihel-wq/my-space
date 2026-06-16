"""
Trading Backtest Data Template
===============================
Use this script to add new trades to your CSV file.
Just fill in the values and run!
"""
import csv
import os

# === FILL IN YOUR TRADE DATA HERE ===
new_trade = {
    "trade_number": 1,
    "date": "2026-06-16",
    "pair": "XAU/USD",
    "timeframe": "5min",
    "direction": "SELL",  # BUY or SELL
    "entry": 4338.19,
    "sl": 4348.61,
    "r1_1": 4331.77,
    "r1_2": 4324.92,
    "r1_3": 4318.81,
}

# === AUTO CALCULATIONS ===
def calculate_rr(entry, sl, tp, direction):
    """Calculate Risk:Reward ratio"""
    if direction == "SELL":
        risk = sl - entry
        reward = entry - tp
    else:  # BUY
        risk = entry - sl
        reward = tp - entry
    return round(reward / risk, 2) if risk != 0 else 0

trade = new_trade
risk = abs(trade["sl"] - trade["entry"])
r1_1_reward = abs(trade["entry"] - trade["r1_1"])
r1_2_reward = abs(trade["entry"] - trade["r1_2"])
r1_3_reward = abs(trade["entry"] - trade["r1_3"])

rr_1_1 = calculate_rr(trade["entry"], trade["sl"], trade["r1_1"], trade["direction"])
rr_1_2 = calculate_rr(trade["entry"], trade["sl"], trade["r1_2"], trade["direction"])
rr_1_3 = calculate_rr(trade["entry"], trade["sl"], trade["r1_3"], trade["direction"])

# === WRITE TO CSV ===
csv_file = "trading_backtest.csv"
file_exists = os.path.exists(csv_file)

with open(csv_file, "a", newline="") as f:
    writer = csv.writer(f)
    if not file_exists:
        writer.writerow([
            "Trade #", "Date", "Pair", "Timeframe", "Direction",
            "Entry Price", "Stop Loss (SL)", "R1.1", "R1.2", "R1.3",
            "Risk (pips)", "R1.1 Reward", "R1.2 Reward", "R1.3 Reward",
            "RR 1.1", "RR 1.2", "RR 1.3"
        ])
    writer.writerow([
        trade["trade_number"], trade["date"], trade["pair"],
        trade["timeframe"], trade["direction"],
        trade["entry"], trade["sl"],
        trade["r1_1"], trade["r1_2"], trade["r1_3"],
        round(risk, 2), round(r1_1_reward, 2),
        round(r1_2_reward, 2), round(r1_3_reward, 2),
        rr_1_1, rr_1_2, rr_1_3
    ])

print(f"✓ Trade #{trade['trade_number']} added successfully!")
print(f"  Entry: {trade['entry']} | SL: {trade['sl']}")
print(f"  R1.1: {trade['r1_1']} (RR: {rr_1_1})")
print(f"  R1.2: {trade['r1_2']} (RR: {rr_1_2})")
print(f"  R1.3: {trade['r1_3']} (RR: {rr_1_3})")
print(f"  Risk: {round(risk, 2)} pips")
