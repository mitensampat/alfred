# 🦇 Alfred - Your AI-Powered Personal Assistant

> Like Alfred to Batman - an intelligent assistant that analyzes your messages, prepares meeting briefings, and defends your attention.

---

## ⚡ What Alfred Does

**🌅 Morning Briefings**
- Analyzes your iMessages from the last 24 hours
- Highlights urgent conversations and action items
- Identifies who needs a response from you

**📅 Calendar Intelligence**
- Aggregates events from multiple Google Calendars
- Generates executive briefings for external meetings
- Researches attendees and provides context
- Smart filtering (removes duplicates, zero-duration events, blocks)

**⏰ Attention Defense**
- 3pm daily report on priorities
- AI-powered task analysis
- Time management recommendations

**🚀 Performance Optimized**
- Uses Claude Haiku for fast message analysis (3x faster)
- Smart prioritization (top 20 most important threads)
- Parallel processing for speed

---

## 📦 Quick Install

```bash
# 1. Clone the repository
git clone https://github.com/mitensampat/alfred.git
cd alfred

# 2. Run the installer
./install.sh

# 3. Follow the prompts to configure
```

**That's it!** The installer handles everything:
- ✅ Builds the app
- ✅ Installs `alfred` command to your PATH
- ✅ Sets up configuration directory
- ✅ Guides you through setup

---

## 🔑 What You'll Need

### Required
- **macOS 13.0+** (Ventura or later)
- **Anthropic API Key** - Get one at [console.anthropic.com](https://console.anthropic.com/)
  - Sign up for free, get your API key
  - Costs ~$0.25 per day for typical use

### Optional
- **Google Calendar API** - For calendar features
- **SMTP Credentials** - For email delivery of briefings

---

## 🎯 Try It Out

```bash
# See tomorrow's calendar
alfred calendar tomorrow

# Get a morning briefing
alfred briefing

# Check recent messages
alfred messages imessage 1h

# Get help
alfred --help
```

---

## 🎨 Example Output

```
=== CALENDAR BRIEFING ===
Date: 16 January 2026

Total Events: 8
Total Meeting Time: 7h 35m
Focus Time Available: 2h 30m
External Meetings: 5

TODAY'S SCHEDULE
----------------

10:00 AM - 10:30 AM
  [Terra 0A] Governance Risk & Compliance Review
  👥 5 attendees (1 external)
  📍 Terra-G-0A-Meeting Room (4) [VC]

EXTERNAL MEETING BRIEFINGS
---------------------------

[Terra 0A] Governance Risk & Compliance Review
Time: 10:00 AM - 10:30 AM

Context:
This is a Governance, Risk & Compliance review for Terra 0A
operations focusing on regulatory compliance and risk management...

Preparation:
Review current compliance status reports, recent risk assessments...
```

---

## 🛠️ Setup Details

### 1. Get Your API Key
1. Visit [console.anthropic.com](https://console.anthropic.com/)
2. Sign up or log in
3. Go to "API Keys" → "Create Key"
4. Copy your key

### 2. Configure Alfred
After installation, edit your config:
```bash
nano ~/.config/alfred/config.json
```

Add your API key:
```json
{
  "ai": {
    "anthropic_api_key": "sk-ant-api03-YOUR-KEY-HERE"
  }
}
```

### 3. (Optional) Set Up Calendar
For calendar features:
1. Create a Google Cloud project
2. Enable Calendar API
3. Create OAuth credentials
4. Add to config
5. Run `alfred auth`

Full instructions: [Calendar Setup Guide](https://github.com/mitensampat/alfred/blob/main/MULTIPLE_CALENDARS.md)

### 4. (Optional) Grant iMessage Access
For message analysis:
1. System Settings → Privacy & Security → Full Disk Access
2. Add your Terminal app
3. Restart Terminal

---

## 💡 Pro Tips

**Scheduled Briefings**
```bash
alfred schedule  # Runs 7am briefing + 3pm attention defense
```

**Email Delivery**
```bash
alfred briefing tomorrow --email  # Sends to your inbox
```

**Multiple Calendars**
Alfred can aggregate from personal + work calendars automatically!

**Smart Filtering**
- Automatically removes duplicate events
- Filters out "block" meetings and short events
- Prioritizes external meetings for briefings

---

## 📚 Resources

- **GitHub Repository**: [github.com/mitensampat/alfred](https://github.com/mitensampat/alfred)
- **Full Documentation**: See [README.md](https://github.com/mitensampat/alfred/blob/main/README.md)
- **Contributing Guide**: See [CONTRIBUTING.md](https://github.com/mitensampat/alfred/blob/main/CONTRIBUTING.md)
- **Issues/Support**: [GitHub Issues](https://github.com/mitensampat/alfred/issues)

---

## 🔒 Privacy & Security

- ✅ Runs entirely locally on your Mac
- ✅ Only sends summaries (not full content) to Claude API
- ✅ No data stored permanently
- ✅ All credentials stay in your local config
- ✅ Open source - audit the code yourself

---

## 💰 Cost Estimate

With typical usage (daily briefings + calendar):
- **~$0.15-0.30 per day** with Haiku
- **~$5-10 per month** total

Anthropic offers $5 free credits to start!

---

## 🤝 Questions?

- Check the [README](https://github.com/mitensampat/alfred/blob/main/README.md)
- Open an [Issue](https://github.com/mitensampat/alfred/issues)
- Reach out to Miten

---

## ⚖️ License

MIT License - Free to use, modify, and share!

---

**Built with Swift + Claude Sonnet 4.5**

*Alfred makes you more productive by doing the mundane analysis work, so you can focus on what matters.* 🦇

