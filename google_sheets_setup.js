/**
 * ============================================================
 * 📊 Google Sheets - TradingView Webhook Receiver
 * ============================================================
 * 
 * This Google Apps Script turns your Google Sheet into a webhook
 * endpoint that receives trade data directly from TradingView.
 * 
 * NO SERVER NEEDED! TradingView → Google Sheets directly.
 * 
 * SETUP:
 * ------
 * 1. Create a new Google Sheet
 * 2. Go to Extensions → Apps Script
 * 3. Paste this entire code
 * 4. Click Deploy → New Deployment → Web App
 *    - Execute as: Me
 *    - Who has access: Anyone
 * 5. Copy the Web App URL
 * 6. Use that URL as your webhook in TradingView alerts
 * 
 * ============================================================
 */

// ============================================================
// CONFIGURATION
// ============================================================

const SHEET_NAME = "Trades";           // Name of the sheet tab
const ENABLE_NOTIFICATIONS = true;     // Send email on new trade
const NOTIFICATION_EMAIL = "";         // Your email (leave empty to skip)

// ============================================================
// MAIN WEBHOOK HANDLER
// ============================================================

/**
 * Handles POST requests from TradingView webhooks
 */
function doPost(e) {
  try {
    // Parse incoming JSON data
    let data;
    if (e.postData && e.postData.contents) {
      data = JSON.parse(e.postData.contents);
    } else {
      return createResponse(false, "No data received");
    }

    // Log the raw data for debugging
    Logger.log("Received webhook: " + JSON.stringify(data));

    // Get or create the trades sheet
    const sheet = getOrCreateSheet();

    // Get next trade number
    const lastRow = sheet.getLastRow();
    const tradeNum = lastRow <= 1 ? 1 : lastRow;

    // Extract trade data
    const now = new Date();
    const entry = data.entry || data.entryPrice || "";
    const sl = data.sl || data.stopLoss || "";
    const tp1 = data.tp1 || data.r1_1 || "";
    const tp2 = data.tp2 || data.r1_2 || "";
    const tp3 = data.tp3 || data.r1_3 || "";
    const pair = data.pair || data.symbol || data.ticker || "Unknown";
    const direction = (data.direction || data.side || "").toUpperCase();
    const timeframe = data.timeframe || data.tf || "";

    // Calculate risk and RR
    const risk = Math.abs(parseFloat(entry) - parseFloat(sl)) || 0;
    const rr1 = data.rr1 || (risk > 0 && tp1 ? (Math.abs(parseFloat(entry) - parseFloat(tp1)) / risk).toFixed(2) : "");
    const rr2 = data.rr2 || (risk > 0 && tp2 ? (Math.abs(parseFloat(entry) - parseFloat(tp2)) / risk).toFixed(2) : "");
    const rr3 = data.rr3 || (risk > 0 && tp3 ? (Math.abs(parseFloat(entry) - parseFloat(tp3)) / risk).toFixed(2) : "");

    // Build the row
    const row = [
      tradeNum,                              // Trade #
      Utilities.formatDate(now, Session.getScriptTimeZone(), "yyyy-MM-dd"),  // Date
      Utilities.formatDate(now, Session.getScriptTimeZone(), "HH:mm:ss"),    // Time
      pair,                                  // Pair
      timeframe,                             // Timeframe
      direction,                             // Direction
      entry,                                 // Entry Price
      sl,                                    // Stop Loss
      tp1,                                   // TP1 (R1.1)
      tp2,                                   // TP2 (R1.2)
      tp3,                                   // TP3 (R1.3)
      risk.toFixed(2),                       // Risk
      rr1,                                   // RR1
      rr2,                                   // RR2
      rr3,                                   // RR3
      "OPEN",                                // Status
      data.notes || ""                       // Notes
    ];

    // Append to sheet
    sheet.appendRow(row);

    // Apply formatting to new row
    formatNewRow(sheet, lastRow + 1, direction);

    // Send notification if enabled
    if (ENABLE_NOTIFICATIONS && NOTIFICATION_EMAIL) {
      sendTradeNotification(data, tradeNum);
    }

    Logger.log("Trade #" + tradeNum + " saved successfully");
    return createResponse(true, "Trade #" + tradeNum + " logged", { trade_number: tradeNum });

  } catch (error) {
    Logger.log("Error: " + error.toString());
    return createResponse(false, "Error: " + error.toString());
  }
}

/**
 * Handles GET requests (for testing)
 */
function doGet(e) {
  const sheet = getOrCreateSheet();
  const lastRow = sheet.getLastRow();
  const tradeCount = Math.max(0, lastRow - 1);

  return createResponse(true, "TradingView Trade Logger is active", {
    trades_logged: tradeCount,
    status: "ready",
    instructions: "Send POST requests with trade data JSON"
  });
}

// ============================================================
// SHEET MANAGEMENT
// ============================================================

/**
 * Get existing sheet or create with headers
 */
function getOrCreateSheet() {
  const ss = SpreadsheetApp.getActiveSpreadsheet();
  let sheet = ss.getSheetByName(SHEET_NAME);

  if (!sheet) {
    sheet = ss.insertSheet(SHEET_NAME);
    setupHeaders(sheet);
  } else if (sheet.getLastRow() === 0) {
    setupHeaders(sheet);
  }

  return sheet;
}

/**
 * Setup column headers with formatting
 */
function setupHeaders(sheet) {
  const headers = [
    "Trade #", "Date", "Time", "Pair", "Timeframe", "Direction",
    "Entry", "Stop Loss", "TP1 (R1.1)", "TP2 (R1.2)", "TP3 (R1.3)",
    "Risk", "RR1", "RR2", "RR3", "Status", "Notes"
  ];

  sheet.getRange(1, 1, 1, headers.length).setValues([headers]);

  // Format headers
  const headerRange = sheet.getRange(1, 1, 1, headers.length);
  headerRange.setFontWeight("bold");
  headerRange.setBackground("#1a1a2e");
  headerRange.setFontColor("#ffffff");
  headerRange.setHorizontalAlignment("center");

  // Set column widths
  sheet.setColumnWidth(1, 60);   // Trade #
  sheet.setColumnWidth(2, 100);  // Date
  sheet.setColumnWidth(3, 80);   // Time
  sheet.setColumnWidth(4, 100);  // Pair
  sheet.setColumnWidth(5, 80);   // Timeframe
  sheet.setColumnWidth(6, 80);   // Direction
  sheet.setColumnWidth(7, 100);  // Entry
  sheet.setColumnWidth(8, 100);  // SL
  sheet.setColumnWidth(9, 100);  // TP1
  sheet.setColumnWidth(10, 100); // TP2
  sheet.setColumnWidth(11, 100); // TP3
  sheet.setColumnWidth(12, 80);  // Risk
  sheet.setColumnWidth(13, 60);  // RR1
  sheet.setColumnWidth(14, 60);  // RR2
  sheet.setColumnWidth(15, 60);  // RR3
  sheet.setColumnWidth(16, 80);  // Status
  sheet.setColumnWidth(17, 200); // Notes

  // Freeze header row
  sheet.setFrozenRows(1);
}

/**
 * Format a new trade row based on direction
 */
function formatNewRow(sheet, rowNum, direction) {
  const directionCell = sheet.getRange(rowNum, 6);

  if (direction === "BUY") {
    directionCell.setBackground("#d4edda");
    directionCell.setFontColor("#155724");
  } else if (direction === "SELL") {
    directionCell.setBackground("#f8d7da");
    directionCell.setFontColor("#721c24");
  }

  // Center align all cells
  sheet.getRange(rowNum, 1, 1, 17).setHorizontalAlignment("center");
}

// ============================================================
// NOTIFICATIONS
// ============================================================

/**
 * Send email notification for new trade
 */
function sendTradeNotification(data, tradeNum) {
  const subject = `📊 New Trade #${tradeNum}: ${data.direction} ${data.pair}`;
  const body = `
New trade logged from TradingView:

Trade #: ${tradeNum}
Pair: ${data.pair || "Unknown"}
Direction: ${data.direction || "Unknown"}
Entry: ${data.entry || "N/A"}
Stop Loss: ${data.sl || "N/A"}
TP1 (R1.1): ${data.tp1 || "N/A"}
TP2 (R1.2): ${data.tp2 || "N/A"}
TP3 (R1.3): ${data.tp3 || "N/A"}

Time: ${new Date().toLocaleString()}
  `;

  try {
    MailApp.sendEmail(NOTIFICATION_EMAIL, subject, body);
  } catch (e) {
    Logger.log("Email notification failed: " + e.toString());
  }
}

// ============================================================
// UTILITY FUNCTIONS
// ============================================================

/**
 * Create a JSON response
 */
function createResponse(success, message, data) {
  const response = {
    success: success,
    message: message,
    timestamp: new Date().toISOString()
  };

  if (data) {
    response.data = data;
  }

  return ContentService
    .createTextOutput(JSON.stringify(response))
    .setMimeType(ContentService.MimeType.JSON);
}

// ============================================================
// DASHBOARD & STATS (Bonus)
// ============================================================

/**
 * Create a dashboard/stats sheet
 * Run this manually from Apps Script to generate stats
 */
function createDashboard() {
  const ss = SpreadsheetApp.getActiveSpreadsheet();
  let dashboard = ss.getSheetByName("Dashboard");

  if (!dashboard) {
    dashboard = ss.insertSheet("Dashboard");
  } else {
    dashboard.clear();
  }

  const tradesSheet = ss.getSheetByName(SHEET_NAME);
  if (!tradesSheet || tradesSheet.getLastRow() <= 1) {
    dashboard.getRange(1, 1).setValue("No trades logged yet!");
    return;
  }

  const lastRow = tradesSheet.getLastRow();
  const data = tradesSheet.getRange(2, 1, lastRow - 1, 17).getValues();

  // Calculate stats
  const totalTrades = data.length;
  const buyTrades = data.filter(r => r[5] === "BUY").length;
  const sellTrades = data.filter(r => r[5] === "SELL").length;
  const openTrades = data.filter(r => r[15] === "OPEN").length;
  const winTrades = data.filter(r => r[15] === "WIN").length;
  const lossTrades = data.filter(r => r[15] === "LOSS").length;
  const winRate = (winTrades + lossTrades) > 0
    ? ((winTrades / (winTrades + lossTrades)) * 100).toFixed(1) + "%"
    : "N/A";

  // Pairs breakdown
  const pairs = {};
  data.forEach(r => {
    const pair = r[3] || "Unknown";
    pairs[pair] = (pairs[pair] || 0) + 1;
  });

  // Write dashboard
  dashboard.getRange(1, 1).setValue("📊 TRADING BACKTEST DASHBOARD");
  dashboard.getRange(1, 1).setFontSize(16).setFontWeight("bold");

  const stats = [
    ["", ""],
    ["Total Trades", totalTrades],
    ["Buy Trades", buyTrades],
    ["Sell Trades", sellTrades],
    ["Open Trades", openTrades],
    ["Win Trades", winTrades],
    ["Loss Trades", lossTrades],
    ["Win Rate", winRate],
    ["", ""],
    ["PAIRS BREAKDOWN", "Count"],
  ];

  // Add pairs
  Object.entries(pairs).forEach(([pair, count]) => {
    stats.push([pair, count]);
  });

  dashboard.getRange(2, 1, stats.length, 2).setValues(stats);

  // Format
  dashboard.getRange(2, 1, stats.length, 2).setFontSize(11);
  dashboard.getRange(3, 1, 6, 1).setFontWeight("bold");
  dashboard.setColumnWidth(1, 200);
  dashboard.setColumnWidth(2, 100);

  SpreadsheetApp.getUi().alert("Dashboard updated! ✓");
}

// ============================================================
// MENU (adds custom menu to Google Sheets)
// ============================================================

function onOpen() {
  const ui = SpreadsheetApp.getUi();
  ui.createMenu('📊 Trade Logger')
    .addItem('Update Dashboard', 'createDashboard')
    .addItem('Test Webhook (Add Sample Trade)', 'testWebhook')
    .addSeparator()
    .addItem('Setup Sheet', 'setupFromMenu')
    .addToUi();
}

/**
 * Manual setup from menu
 */
function setupFromMenu() {
  getOrCreateSheet();
  SpreadsheetApp.getUi().alert("Sheet setup complete! ✓\n\nDeploy as Web App to receive webhooks.");
}

/**
 * Test webhook by adding a sample trade
 */
function testWebhook() {
  const sheet = getOrCreateSheet();
  const testData = {
    pair: "XAUUSD",
    timeframe: "5",
    direction: "SELL",
    entry: 4338.19,
    sl: 4348.61,
    tp1: 4331.77,
    tp2: 4324.92,
    tp3: 4318.81,
    notes: "Test trade"
  };

  const lastRow = sheet.getLastRow();
  const tradeNum = lastRow <= 1 ? 1 : lastRow;
  const now = new Date();
  const risk = Math.abs(testData.entry - testData.sl);

  const row = [
    tradeNum,
    Utilities.formatDate(now, Session.getScriptTimeZone(), "yyyy-MM-dd"),
    Utilities.formatDate(now, Session.getScriptTimeZone(), "HH:mm:ss"),
    testData.pair,
    testData.timeframe,
    testData.direction,
    testData.entry,
    testData.sl,
    testData.tp1,
    testData.tp2,
    testData.tp3,
    risk.toFixed(2),
    (Math.abs(testData.entry - testData.tp1) / risk).toFixed(2),
    (Math.abs(testData.entry - testData.tp2) / risk).toFixed(2),
    (Math.abs(testData.entry - testData.tp3) / risk).toFixed(2),
    "OPEN",
    testData.notes
  ];

  sheet.appendRow(row);
  formatNewRow(sheet, lastRow + 1, testData.direction);

  SpreadsheetApp.getUi().alert(
    "Test trade added! ✓\n\n" +
    "SELL XAUUSD @ 4338.19\n" +
    "SL: 4348.61\n" +
    "TP1: 4331.77 | TP2: 4324.92 | TP3: 4318.81"
  );
}
