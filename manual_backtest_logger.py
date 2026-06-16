"""
Manual Backtest Logger (Interactive)
=====================================
Run this script and enter trade data manually from your TradingView screenshots.
Faster and more accurate than OCR for small number of trades.

SETUP:
------
pip install pandas openpyxl   (optional, for .xlsx export)

USAGE:
------
python manual_backtest_logger.py
"""

import csv
import os
import sys
from datetime import datetime

try:
    import pandas as pd
    HAS_PANDAS = True
except ImportError:
    HAS_PANDAS = False

OUTPUT_CSV = "backtest_results.csv"
OUTPUT_XLSX = "backtest_results.xlsx"

HEADERS = [
    'Trade #', 'Date', 'Time', 'Pair', 'Timeframe', 'Direction',
    'Entry Price', 'Stop Loss', 'R1.1', 'R1.2', 'R1.3',
    'Risk (pips)', 'R1.1 Reward', 'R1.2 Reward', 'R1.3 Reward',
    'RR 1.1', 'RR 1.2', 'RR 1.3', 'Result', 'Notes'
]


def get_next_trade_number():
    """Get the next trade number from existing CSV."""
    if not os.path.exists(OUTPUT_CSV):
        return 1
    with open(OUTPUT_CSV, 'r') as f:
        reader = csv.reader(f)
        rows = list(reader)
        if len(rows) <= 1:
            return 1
        try:
            last_num = int(rows[-1][0])
            return last_num + 1
        except (ValueError, IndexError):
            return len(rows)


def input_float(prompt, required=True):
    """Get float input from user."""
    while True:
        val = input(prompt).strip()
        if not val and not required:
            return None
        try:
            return float(val.replace(',', ''))
        except ValueError:
            print("  ⚠ Enter a valid number (e.g., 4338.19)")


def input_choice(prompt, choices):
    """Get choice input from user."""
    while True:
        val = input(prompt).strip().upper()
        if val in [c.upper() for c in choices]:
            return val
        print(f"  ⚠ Choose from: {', '.join(choices)}")


def log_trade():
    """Interactive trade logging."""
    trade_num = get_next_trade_number()

    print(f"\n{'='*50}")
    print(f"  📊 NEW TRADE #{trade_num}")
    print(f"{'='*50}\n")

    # Basic info
    pair = input("  Pair (default: XAU/USD): ").strip() or "XAU/USD"
    timeframe = input("  Timeframe (default: 5min): ").strip() or "5min"
    direction = input_choice("  Direction (BUY/SELL): ", ['BUY', 'SELL'])
    date = input(f"  Date (default: {datetime.now().strftime('%Y-%m-%d')}): ").strip()
    date = date or datetime.now().strftime('%Y-%m-%d')
    time_val = input("  Time (e.g., 06:00, or press Enter): ").strip() or ""

    print()

    # Price levels
    entry = input_float("  Entry Price: ")
    sl = input_float("  Stop Loss (SL): ")
    r1_1 = input_float("  R1.1 (TP1): ")
    r1_2 = input_float("  R1.2 (TP2): ", required=False)
    r1_3 = input_float("  R1.3 (TP3): ", required=False)

    # Result
    print()
    result = input("  Result (WIN/LOSS/BE/OPEN, or press Enter): ").strip().upper() or ""
    notes = input("  Notes (optional): ").strip() or ""

    # Calculate RR
    risk = abs(sl - entry)
    r1_1_reward = abs(entry - r1_1) if r1_1 else 0
    r1_2_reward = abs(entry - r1_2) if r1_2 else 0
    r1_3_reward = abs(entry - r1_3) if r1_3 else 0

    rr_1_1 = round(r1_1_reward / risk, 2) if risk > 0 and r1_1 else ""
    rr_1_2 = round(r1_2_reward / risk, 2) if risk > 0 and r1_2 else ""
    rr_1_3 = round(r1_3_reward / risk, 2) if risk > 0 and r1_3 else ""

    # Build row
    row = [
        trade_num, date, time_val, pair, timeframe, direction,
        entry, sl,
        r1_1 or "", r1_2 or "", r1_3 or "",
        round(risk, 2),
        round(r1_1_reward, 2) if r1_1 else "",
        round(r1_2_reward, 2) if r1_2 else "",
        round(r1_3_reward, 2) if r1_3 else "",
        rr_1_1, rr_1_2, rr_1_3,
        result, notes
    ]

    # Write to CSV
    file_exists = os.path.exists(OUTPUT_CSV)
    with open(OUTPUT_CSV, 'a', newline='') as f:
        writer = csv.writer(f)
        if not file_exists:
            writer.writerow(HEADERS)
        writer.writerow(row)

    # Summary
    print(f"\n{'='*50}")
    print(f"  ✅ Trade #{trade_num} saved!")
    print(f"{'='*50}")
    print(f"  {direction} {pair} @ {entry}")
    print(f"  SL: {sl} | Risk: {round(risk, 2)}")
    if r1_1: print(f"  R1.1: {r1_1} | RR: {rr_1_1}")
    if r1_2: print(f"  R1.2: {r1_2} | RR: {rr_1_2}")
    if r1_3: print(f"  R1.3: {r1_3} | RR: {rr_1_3}")
    if result: print(f"  Result: {result}")
    print(f"\n  📁 Saved to: {OUTPUT_CSV}")

    return True


def export_to_excel():
    """Export CSV to Excel with formatting."""
    if not HAS_PANDAS:
        print("  ⚠ Install pandas and openpyxl for Excel export:")
        print("    pip install pandas openpyxl")
        return

    if not os.path.exists(OUTPUT_CSV):
        print("  ⚠ No CSV file found. Log some trades first!")
        return

    df = pd.read_csv(OUTPUT_CSV)
    df.to_excel(OUTPUT_XLSX, index=False, engine='openpyxl')
    print(f"\n  ✅ Exported to: {OUTPUT_XLSX}")
    print(f"     {len(df)} trade(s) in file")


def show_stats():
    """Show quick backtest statistics."""
    if not os.path.exists(OUTPUT_CSV):
        print("  ⚠ No data yet. Log some trades first!")
        return

    with open(OUTPUT_CSV, 'r') as f:
        reader = csv.DictReader(f)
        trades = list(reader)

    total = len(trades)
    wins = sum(1 for t in trades if t.get('Result', '').upper() == 'WIN')
    losses = sum(1 for t in trades if t.get('Result', '').upper() == 'LOSS')
    be = sum(1 for t in trades if t.get('Result', '').upper() == 'BE')
    open_trades = sum(1 for t in trades if t.get('Result', '').upper() == 'OPEN')

    print(f"\n{'='*50}")
    print(f"  📊 BACKTEST STATISTICS")
    print(f"{'='*50}")
    print(f"  Total Trades:  {total}")
    print(f"  Wins:          {wins}")
    print(f"  Losses:        {losses}")
    print(f"  Break Even:    {be}")
    print(f"  Open:          {open_trades}")
    if wins + losses > 0:
        wr = round(wins / (wins + losses) * 100, 1)
        print(f"  Win Rate:      {wr}%")
    print(f"{'='*50}")


def main():
    """Main menu loop."""
    print("\n" + "="*50)
    print("  📈 TRADING BACKTEST LOGGER")
    print("  Log your TradingView backtest trades easily!")
    print("="*50)

    while True:
        print(f"\n  [1] Log new trade")
        print(f"  [2] Export to Excel (.xlsx)")
        print(f"  [3] Show statistics")
        print(f"  [4] Quit")

        choice = input("\n  Choose (1-4): ").strip()

        if choice == '1':
            log_trade()
        elif choice == '2':
            export_to_excel()
        elif choice == '3':
            show_stats()
        elif choice == '4':
            print("\n  👋 Bye! Happy trading!\n")
            break
        else:
            print("  ⚠ Invalid choice")


if __name__ == "__main__":
    main()
