PhantomCollector for WoW Forever (Interface 16001)

Install: Extract the PhantomCollector folder into _classic_beta_/Interface/AddOns/
Open: /pc or /phantomcollector

1. Opening a trade remembers a trade contact (it does NOT assume a loan was made).
2. Select a contact or enter a character name and click Add / Select.
3. Enter gold, silver, copper, interest %, period, and interest type (Compound or Simple), then Save Debt.
   Interest type is set per borrower, so one person can compound while another uses simple interest.
4. Use Announce to post the debt into your selected chat channel (SAY, PARTY, RAID, GUILD).
5. Use Settings to customize color palette, the default interest type for new debts, and show/hide the trade prompt.
6. Clear No-Debt (above the contact list) removes every contact without an active debt. Click it twice within
   10 seconds to confirm. Borrowing history is kept and reappears if you add that player again.

Interest is applied once per COMPLETE configured interval (compound: on the running balance; simple: on the original principal), based on the original start time. Interest calculations are derived from the stored principal and start date; they do not depend on continuous login. Monthly periods are approximated as 30 days. Custom interval is an integer number of hours.

The debtor's name and the creditor's character name are stored with the record.
Trade contacts are captured when trade UI opens, not verified successful trades.
Trade windows may be opened and cancelled; manually manage records accordingly.
SavedVariables are written by the WoW client on logout/reload, not continuously to disk.
No collection, mail, or gold transfer is automated.
