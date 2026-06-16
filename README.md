# 📊 TradingView Backtest Auto-Logger

> **سجّل trades ديالك أوتوماتيكيا من TradingView لـ Google Sheets / Excel**

نظام كامل كيربط TradingView مع Google Sheets باش كل trade تديرها يتسجل أوتوماتيكيا مع Entry, SL, TP1, TP2, TP3 و Risk:Reward.

---

## 🏗️ Architecture (كيفاش خدام)

```
┌─────────────────┐         ┌──────────────────┐         ┌─────────────────┐
│   TradingView   │  Alert  │  Webhook Server  │  POST   │  Google Sheets  │
│   Pine Script   │ ──────► │  (Python/Flask)  │ ──────► │  (Apps Script)  │
│                 │         │  + Local CSV     │         │                 │
└─────────────────┘         └──────────────────┘         └─────────────────┘
        │                                                         ▲
        │                    OR (Direct - No Server)               │
        └─────────────────────────────────────────────────────────┘
```

**طريقتين:**
- **Method A:** TradingView → Google Sheets مباشرة (بلا server)
- **Method B:** TradingView → Python Server → Google Sheets + CSV

---

## 📁 Files Overview

| File | Description |
|------|-------------|
| `pinescript_trade_logger.pine` | Pine Script - Manual trade logger (تدير trades يدويا) |
| `pinescript_auto_strategy.pine` | Pine Script - Auto strategy (يكتشف trades أوتوماتيكيا) |
| `google_sheets_setup.js` | Google Apps Script - يستقبل webhooks مباشرة ف Sheets |
| `webhook_server.py` | Python server - يستقبل webhooks و يحفظ ف CSV |
| `webhook_to_sheets.py` | Python bridge - يستقبل و يبعث ل Google Sheets |

---

## 🚀 Quick Start

### Method A: مباشرة بلا Server (الأسهل) ⭐

هاد الطريقة ماتحتاج حتى server — TradingView كيبعت مباشرة ل Google Sheets.

#### Step 1: إنشاء Google Sheet

1. مشي ل [Google Sheets](https://sheets.google.com) و خلق sheet جديد
2. سميه: `Trading Backtest`

#### Step 2: إضافة Apps Script

1. فتح الsheet ← **Extensions** ← **Apps Script**
2. مسح الcode الافتراضي
3. الصق محتوى `google_sheets_setup.js` كامل
4. احفظ (Ctrl+S)

#### Step 3: Deploy كـ Web App

1. ف Apps Script: **Deploy** ← **New deployment**
2. اختار **Web app**
3. Settings:
   - Execute as: **Me**
   - Who has access: **Anyone**
4. Click **Deploy**
5. **انسخ الURL** اللي عطاك (هاد هو webhook URL ديالك)

#### Step 4: إضافة Pine Script ف TradingView

1. فتح TradingView ← **Pine Editor**
2. الصق محتوى `pinescript_trade_logger.pine`
3. Click **Add to Chart**

#### Step 5: إنشاء Alert مع Webhook

1. ف TradingView: Click **Alert** (⏰)
2. Condition: **Trade Logger - Backtest**
3. فتح **Notifications** tab
4. شعّل ✅ **Webhook URL**
5. لصق الURL ديال Google Sheets Web App
6. ف **Alert Message** اكتب:

```json
{"pair":"{{ticker}}","timeframe":"{{interval}}","direction":"SELL","entry":{{close}},"sl":0,"tp1":0,"tp2":0,"tp3":0}
```

7. Click **Create**

✅ **خلاص!** كل مرة تشعّل الalert، الtrade كيتسجل ف Google Sheets.

---

### Method B: مع Python Server (أكثر تحكم)

#### Step 1: Install Dependencies

```bash
pip install flask pandas openpyxl requests
```

#### Step 2: شغّل Server

```bash
python webhook_server.py
```

#### Step 3: خلي Server accessible من الانترنت

Option 1: **ngrok** (للتجربة)
```bash
# Install ngrok: https://ngrok.com/download
ngrok http 5000
# انسخ الURL: https://xxxx.ngrok.io
```

Option 2: **Deploy على cloud** (للاستعمال الدائم)
- Railway.app (free tier)
- Render.com (free tier)  
- Heroku
- VPS (DigitalOcean, etc.)

#### Step 4: ربط TradingView

استعمل الURL ديال ngrok/cloud كـ webhook:
```
https://xxxx.ngrok.io/webhook
```

---

## 📝 Pine Scripts Explained

### 1. Manual Logger (`pinescript_trade_logger.pine`)

هاد الscript كيخليك **تدخل trades يدويا**:
- تعمّر Entry, SL, TP1, TP2, TP3 ف settings
- كيرسملهم على الchart
- كيحسب Risk:Reward
- ملي تشعّل "Trigger Alert" كيبعث webhook

**مزيان لـ:** Backtesting يدوي، تسجيل trades محددين.

### 2. Auto Strategy (`pinescript_auto_strategy.pine`)

هاد الscript كيكتشف trades **أوتوماتيكيا** بناءً على:
- EMA Crossover (9/21)
- RSI Confirmation
- ATR-based SL/TP

**مزيان لـ:** Backtesting أوتوماتيكي، تجربة strategy.

> ⚠️ **مهم:** عدّل conditions ديال الدخول باش تناسب strategy ديالك!

---

## 📊 البيانات اللي كتتسجل

| Column | وصف |
|--------|------|
| Trade # | رقم الtrade |
| Date | التاريخ |
| Time | الوقت |
| Pair | الزوج (XAU/USD, EUR/USD...) |
| Timeframe | الإطار الزمني |
| Direction | BUY أو SELL |
| Entry | سعر الدخول |
| Stop Loss | وقف الخسارة |
| TP1 (R1.1) | الهدف الأول |
| TP2 (R1.2) | الهدف الثاني |
| TP3 (R1.3) | الهدف الثالث |
| Risk | المخاطرة (بالنقط) |
| RR1 / RR2 / RR3 | نسبة Risk:Reward |
| Status | OPEN / WIN / LOSS / BE |

---

## 🔧 Customization

### تغيير R:R Ratios

ف `pinescript_auto_strategy.pine`:
```pine
riskReward1 = input.float(1.1, "R:R for TP1")  // ← غيّر هنا
riskReward2 = input.float(2.2, "R:R for TP2")
riskReward3 = input.float(3.3, "R:R for TP3")
```

### تغيير Entry Conditions

ف `pinescript_auto_strategy.pine`, عدّل هاد الجزء:
```pine
// ====== CUSTOMIZE THESE ======
buyCondition = ta.crossover(fastMA, slowMA) and rsi < rsiOversold + 10
sellCondition = ta.crossunder(fastMA, slowMA) and rsi > rsiOverbought - 10
```

### إضافة Security Token

ف `webhook_server.py`:
```bash
export WEBHOOK_SECRET="your_secret_token_here"
```

ف TradingView alert, زيد header:
```
X-Webhook-Token: your_secret_token_here
```

---

## 🧪 Testing

### Test Webhook Server
```bash
# Start server
python webhook_server.py

# Test (in another terminal)
curl -X POST http://localhost:5000/webhook \
  -H "Content-Type: application/json" \
  -d '{"pair":"XAUUSD","direction":"SELL","entry":4338.19,"sl":4348.61,"tp1":4331.77,"tp2":4324.92,"tp3":4318.81}'
```

### Test Google Sheets
1. فتح الSheet ← menu **📊 Trade Logger** ← **Test Webhook**

### View Logged Trades
```bash
# Via API
curl http://localhost:5000/trades

# Statistics
curl http://localhost:5000/stats
```

---

## 🛠️ Troubleshooting

| المشكلة | الحل |
|---------|------|
| Webhook ما كيوصلش | تأكد ngrok شغال + URL صحيح |
| Google Sheets ما كيستقبلش | تأكد Deploy = "Anyone" access |
| Pine Script error | تأكد Version = //@version=5 |
| Prices غالطين | عدّلهم يدويا ف settings ديال indicator |
| TradingView ما كيبعتش alert | تأكد Alert مفعّل + Webhook مشعّل |

---

## 📱 Workflow اليومي

```
1. فتح TradingView
2. حلّل الchart ديالك
3. ملي تلقى trade:
   a. عمّر Entry/SL/TP ف indicator settings
   b. شعّل "Trigger Alert"
   → Trade كيتسجل أوتوماتيكيا ف Google Sheets! ✓
4. ف نهاية اليوم: شوف الsheet ديالك مع كل الtrades
```

---

## 📋 Requirements

- **TradingView:** Pro plan أو أعلى (webhook alerts)
- **Python:** 3.7+ (إلا بغيت server)
- **Google Account:** مجاني (ل Google Sheets)

### Python Dependencies
```bash
pip install flask pandas openpyxl requests
```

---

## 🔮 Future Improvements

- [ ] Auto-detect WIN/LOSS based on price hitting TP or SL
- [ ] Telegram/Discord notifications
- [ ] Web dashboard with charts
- [ ] Multiple strategies tracking
- [ ] Auto-calculate daily/weekly/monthly stats
- [ ] Screenshot attachment to each trade

---

## 📄 License

MIT - استعملو كيف ما بغيتي! 🚀

---

**Made with ❤️ for traders who want to track their backtest data efficiently.**
