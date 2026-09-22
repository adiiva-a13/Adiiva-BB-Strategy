//+------------------------------------------------------------------+
//|                                          AdiivaPvpStrategy.mq5   |
//|  Port MT5 al "Adiiva PVP Strategy" (Pine Script v5, TradingView) |
//|                                                                    |
//|  Diferente fata de scriptul Pine original:                       |
//|   - Eliminat complet tracking-ul NY.H/NY.L si NY 4H.H/4H.L        |
//|     (erau doar vizuale in TradingView, cerute explicit afara).   |
//|   - Sesiunile (PVP/Trade/Entry) sunt definite in ora Romaniei,   |
//|     calculate din server time + input GMT offset + regula DST UE  |
//|     (ultima duminica din martie -> ultima duminica din octombrie).|
//|     Seteaza InpBrokerGmtOffsetHours dupa broker-ul tau.          |
//|   - Dimensionarea pozitiei foloseste risc % din echitate impartit|
//|     la distanta SL (standard pentru trading real), NU "percent   |
//|     of equity" notional ca in Pine (care e o simplificare de     |
//|     backtester si nu are echivalent direct la brokerii reali).   |
//|   - VWAP de sesiune se reseteaza la inceputul fiecarei zile de   |
//|     tranzactionare (00:00 server time) - Pine foloseste anchor=  |
//|     session, care in TradingView urmeaza sesiunea definita de    |
//|     simbol; aceasta e cea mai apropiata aproximare general-       |
//|     valabila in MT5.                                              |
//+------------------------------------------------------------------+
#property copyright "Adiiva"
#property version   "1.00"
#property strict

#include <Trade\Trade.mqh>
#include <Trade\PositionInfo.mqh>
#include <Trade\HistoryOrderInfo.mqh>
#include <Trade\DealInfo.mqh>

CTrade        trade;
CPositionInfo posInfo;
CDealInfo     dealInfo;

//================================================================================
// INPUTS
//================================================================================
input group "Volume Profile (PVP)"
input int    InpNumRows          = 500;    // Number of Rows
input double InpVaPct             = 68.0;   // Value Area %

input group "Strategy"
input double InpRR                = 1.5;    // RR Ratio
input double InpRiskPercent       = 1.0;    // Risc % din echitate per tranzactie (sizing pe distanta SL)
input int    InpMagic             = 20260701; // Magic Number

input group "Sesiune (ora Romaniei, calculata din server time)"
input int    InpBrokerGmtOffsetHours = 2;   // Offset server broker fata de GMT/UTC (ore)
input int    InpPvpStartHour      = 12;     // PVP start (RO)
input int    InpPvpEndHour        = 16;     // PVP end / Trade start (RO)
input int    InpTradeEndHour      = 22;     // Trade session end (RO)
input int    InpEntryEndHour      = 19;     // Entry window end (RO)

//================================================================================
// STARE GLOBALA
//================================================================================
datetime g_lastBarTime = 0;
long     g_barCounter  = 0;

bool g_isPvpPrev   = false;
bool g_isTradePrev = false;

// --- Volume Profile ---
double g_pvpHigh[];
double g_pvpLow[];
double g_pvpVol[];
int    g_pvpCount = 0;
double g_vah = EMPTY_VALUE;
double g_val = EMPTY_VALUE;
double g_poc = EMPTY_VALUE;

// --- VWAP sesiune (resetat la inceput de zi noua, server time) ---
double   g_vwapWPSum = 0.0;
double   g_vwapVSum  = 0.0;
double   g_sessionVwap = EMPTY_VALUE;
int      g_vwapDay = -1;

// --- MSS detection ---
double g_trackedSh   = EMPTY_VALUE;
double g_trackedSl   = EMPTY_VALUE;
double g_bearSeqSl   = EMPTY_VALUE;
double g_bullSeqSh   = EMPTY_VALUE;
double g_bullMssLvl  = EMPTY_VALUE;
double g_bearMssLvl  = EMPTY_VALUE;
double g_bullMssSl   = EMPTY_VALUE;
double g_bearMssSl   = EMPTY_VALUE;
bool   g_mssPendingLong  = false;
bool   g_mssPendingShort = false;

// --- Strategy state ---
int    g_tradesToday  = 0;
bool   g_lastWasSl    = false;
bool   g_waitingLong  = false;
bool   g_waitingShort = false;
long   g_setupBarL    = -1;
long   g_setupBarS    = -1;
double g_retestLvlL   = EMPTY_VALUE;
double g_retestLvlS   = EMPTY_VALUE;
double g_slLong       = EMPTY_VALUE;
double g_slShort      = EMPTY_VALUE;

ulong  g_posTicket    = 0;   // pozitia curenta deschisa de EA (0 = nimic deschis)
ulong  g_pendingTicket = 0;  // ordinul pending curent (0 = niciunul)

#define EPS 0.0000001
bool IsSet(double v) { return v != EMPTY_VALUE; }

//================================================================================
// HELPERE PRET / BARE  (conventie: shift-ul e in stilul Pine: 0 = bara curenta
// inchisa, 1 = bara anterioara, etc. Se traduce in shift MT5 = shift_pine + 1,
// pentru ca la momentul OnBar() bara index 0 din MT5 e bara noua, neinchisa.)
//================================================================================
double PC(int shift) { return iClose(_Symbol, _Period, shift + 1); }
double PO(int shift) { return iOpen (_Symbol, _Period, shift + 1); }
double PH(int shift) { return iHigh (_Symbol, _Period, shift + 1); }
double PL(int shift) { return iLow  (_Symbol, _Period, shift + 1); }
long   PV(int shift) { return iVolume(_Symbol, _Period, shift + 1); }
datetime PT(int shift) { return iTime(_Symbol, _Period, shift + 1); }

//================================================================================
// TIMEZONE: ora Romaniei din server time (regula DST UE)
//================================================================================
datetime LastSundayOfMonthUTC(int year, int month, int hourUtc)
{
   // gaseste ultima zi valida a lunii (31 in jos, prima care nu "sare" in luna urmatoare)
   int daysInMonth = 28;
   MqlDateTime tmp;
   for(int d = 31; d >= 28; d--)
   {
      tmp.year = year; tmp.mon = month; tmp.day = d; tmp.hour = 12; tmp.min = 0; tmp.sec = 0;
      datetime probe = StructToTime(tmp);
      MqlDateTime chk; TimeToStruct(probe, chk);
      if(chk.mon == month && chk.day == d) { daysInMonth = d; break; }
   }
   for(int day = daysInMonth; day >= 1; day--)
   {
      MqlDateTime cand;
      cand.year = year; cand.mon = month; cand.day = day; cand.hour = hourUtc; cand.min = 0; cand.sec = 0;
      datetime t = StructToTime(cand);
      MqlDateTime chk; TimeToStruct(t, chk);
      if(chk.day_of_week == 0) return t; // duminica
   }
   return 0;
}

int RomaniaUtcOffsetHours(datetime utcTime)
{
   MqlDateTime dt; TimeToStruct(utcTime, dt);
   datetime dstStart = LastSundayOfMonthUTC(dt.year, 3, 1);
   datetime dstEnd   = LastSundayOfMonthUTC(dt.year, 10, 1);
   if(utcTime >= dstStart && utcTime < dstEnd) return 3; // EEST (vara)
   return 2; // EET (iarna)
}

datetime ToRomaniaTime(datetime serverTime)
{
   datetime utcTime = serverTime - InpBrokerGmtOffsetHours * 3600;
   int roOffset = RomaniaUtcOffsetHours(utcTime);
   return utcTime + roOffset * 3600;
}

void RomaniaHM(datetime serverTime, int &h, int &m)
{
   datetime ro = ToRomaniaTime(serverTime);
   MqlDateTime dt; TimeToStruct(ro, dt);
   h = dt.hour; m = dt.min;
}

bool InWindow(int h, int m, int startH, int endH)
{
   int mins = h * 60 + m;
   return mins >= startH * 60 && mins < endH * 60;
}

//================================================================================
// ORDER / TRADE HELPERS
//================================================================================
double PriceRound(double price)
{
   double tick = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);
   if(tick <= 0) tick = _Point;
   return MathRound(price / tick) * tick;
}

double CalcLots(double slDistPrice)
{
   double equity = AccountInfoDouble(ACCOUNT_EQUITY);
   double riskMoney = equity * InpRiskPercent / 100.0;

   double tickValue = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE);
   double tickSize  = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);
   if(tickSize <= 0) tickSize = _Point;
   if(tickValue <= 0) tickValue = _Point;

   double lossPerLot = (slDistPrice / tickSize) * tickValue;
   if(lossPerLot <= 0) return 0.0;

   double lots = riskMoney / lossPerLot;

   double minLot  = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
   double maxLot  = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX);
   double stepLot = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);
   if(stepLot <= 0) stepLot = minLot;

   lots = MathFloor(lots / stepLot) * stepLot;
   if(lots < minLot) lots = minLot;
   if(lots > maxLot) lots = maxLot;
   return lots;
}

void CancelPending()
{
   if(g_pendingTicket != 0)
   {
      if(OrderSelect(g_pendingTicket))
         trade.OrderDelete(g_pendingTicket);
      g_pendingTicket = 0;
   }
}

bool HasOpenPosition()
{
   return g_posTicket != 0 && posInfo.SelectByTicket(g_posTicket);
}

//================================================================================
// VOLUME PROFILE
//================================================================================
void PvpReset()
{
   g_pvpCount = 0;
   ArrayResize(g_pvpHigh, 0);
   ArrayResize(g_pvpLow, 0);
   ArrayResize(g_pvpVol, 0);
}

void PvpPush(double h, double l, double v)
{
   g_pvpCount++;
   ArrayResize(g_pvpHigh, g_pvpCount);
   ArrayResize(g_pvpLow, g_pvpCount);
   ArrayResize(g_pvpVol, g_pvpCount);
   g_pvpHigh[g_pvpCount - 1] = h;
   g_pvpLow[g_pvpCount - 1]  = l;
   g_pvpVol[g_pvpCount - 1]  = v;
}

void PvpCompute()
{
   if(g_pvpCount <= 0) return;

   double sHi = g_pvpHigh[0], sLo = g_pvpLow[0];
   for(int i = 1; i < g_pvpCount; i++)
   {
      if(g_pvpHigh[i] > sHi) sHi = g_pvpHigh[i];
      if(g_pvpLow[i]  < sLo) sLo = g_pvpLow[i];
   }
   double rng = sHi - sLo;
   if(rng <= 0) return;

   int nr = InpNumRows;
   double rowPx = rng / (double)nr;
   if(rowPx <= 0) return;

   double rv[];
   ArrayResize(rv, nr);
   ArrayInitialize(rv, 0.0);

   for(int i = 0; i < g_pvpCount; i++)
   {
      int ri0 = (int)MathMax(0.0, MathFloor((g_pvpLow[i]  - sLo) / rowPx));
      int ri1 = (int)MathMin((double)(nr - 1), MathFloor((g_pvpHigh[i] - sLo) / rowPx));
      int sp  = ri1 - ri0 + 1;
      if(sp > 0)
      {
         double vpr = g_pvpVol[i] / (double)sp;
         for(int r = ri0; r <= ri1; r++)
            rv[r] += vpr;
      }
   }

   int pocIdx = 0;
   double maxv = 0.0;
   for(int r = 0; r < nr; r++)
   {
      if(rv[r] > maxv) { maxv = rv[r]; pocIdx = r; }
   }
   g_poc = sLo + (pocIdx + 0.5) * rowPx;

   double totv = 0.0;
   for(int r = 0; r < nr; r++) totv += rv[r];
   double tgtv = totv * (InpVaPct / 100.0);
   double accv = maxv;
   int loI = pocIdx, hiI = pocIdx;

   while(accv < tgtv)
   {
      bool cdn = loI > 0;
      bool cup = hiI < nr - 1;
      if(!cdn && !cup) break;
      if(cdn && cup)
      {
         double dv = rv[loI - 1];
         double uv = rv[hiI + 1];
         if(dv >= uv) { loI--; accv += dv; }
         else         { hiI++; accv += uv; }
      }
      else if(cdn) { loI--; accv += rv[loI]; }
      else         { hiI++; accv += rv[hiI]; }
   }

   g_val = sLo + loI * rowPx;
   g_vah = sLo + (hiI + 1) * rowPx;
}

//================================================================================
// INIT / DEINIT
//================================================================================
int OnInit()
{
   trade.SetExpertMagicNumber(InpMagic);
   trade.SetTypeFillingBySymbol(_Symbol);
   PvpReset();
   return(INIT_SUCCEEDED);
}

void OnDeinit(const int reason)
{
}

//================================================================================
// NEW BAR DETECTION
//================================================================================
bool IsNewBar()
{
   datetime t = iTime(_Symbol, _Period, 0);
   if(t != g_lastBarTime)
   {
      g_lastBarTime = t;
      return true;
   }
   return false;
}

//================================================================================
// OnTick
//================================================================================
void OnTick()
{
   // Sincronizeaza starea pozitiei (poate fi inchisa de SL/TP intre bare)
   SyncPositionState();

   if(!IsNewBar()) return;
   g_barCounter++;

   OnBar();
}

//================================================================================
// Detecteaza inchiderea pozitiei (SL/TP hit) si actualizeaza lastWasSl,
// respectiv umplerea unui ordin pending (deschidere pozitie -> trades_today++)
//================================================================================
void SyncPositionState()
{
   // Pozitie noua aparuta (pending order s-a umplut)
   if(g_posTicket == 0 && g_pendingTicket != 0)
   {
      if(PositionSelect(_Symbol))
      {
         ulong ticket = PositionGetInteger(POSITION_TICKET);
         if(PositionGetInteger(POSITION_MAGIC) == InpMagic)
         {
            g_posTicket = ticket;
            g_pendingTicket = 0;
            g_tradesToday++;
            g_waitingLong  = false;
            g_waitingShort = false;
         }
      }
   }

   // Pozitia s-a inchis (SL/TP/manual)
   if(g_posTicket != 0 && !posInfo.SelectByTicket(g_posTicket))
   {
      double profit = 0.0;
      if(HistorySelectByPosition(g_posTicket))
      {
         int total = HistoryDealsTotal();
         for(int i = 0; i < total; i++)
         {
            ulong dealTicket = HistoryDealGetTicket(i);
            if(dealTicket == 0) continue;
            if(HistoryDealGetInteger(dealTicket, DEAL_ENTRY) == DEAL_ENTRY_OUT)
               profit += HistoryDealGetDouble(dealTicket, DEAL_PROFIT)
                       + HistoryDealGetDouble(dealTicket, DEAL_SWAP)
                       + HistoryDealGetDouble(dealTicket, DEAL_COMMISSION);
         }
      }
      g_lastWasSl = (profit < 0.0);
      g_posTicket = 0;
   }
}

//================================================================================
// LOGICA PRINCIPALA - rulata o singura data pe bara noua inchisa
//================================================================================
void OnBar()
{
   int h, m;
   RomaniaHM(TimeCurrent(), h, m);

   bool isPvp   = InWindow(h, m, InpPvpStartHour,  InpPvpEndHour);
   bool isTrade = InWindow(h, m, InpPvpEndHour,    InpTradeEndHour);
   bool isEntry = InWindow(h, m, InpPvpEndHour,    InpEntryEndHour);

   bool pvpStarted = isPvp && !g_isPvpPrev;
   bool pvpEnded    = !isPvp && g_isPvpPrev;
   bool tradeEnded  = !isTrade && g_isTradePrev;

   //--- VWAP sesiune: reset la inceput de zi noua (server time) ---
   MqlDateTime dtNow; TimeToStruct(TimeCurrent(), dtNow);
   int todayKey = dtNow.year * 10000 + dtNow.mon * 100 + dtNow.day;
   if(todayKey != g_vwapDay)
   {
      g_vwapDay = todayKey;
      g_vwapWPSum = 0.0;
      g_vwapVSum  = 0.0;
   }
   double hlc3 = (PH(0) + PL(0) + PC(0)) / 3.0;
   double vol0 = (double)PV(0);
   g_vwapWPSum += hlc3 * vol0;
   g_vwapVSum  += vol0;
   g_sessionVwap = (g_vwapVSum > 0.0) ? (g_vwapWPSum / g_vwapVSum) : EMPTY_VALUE;

   //--- VOLUME PROFILE (sesiunea PVP) ---
   if(pvpStarted)
      PvpReset();
   if(isPvp)
      PvpPush(PH(0), PL(0), (double)PV(0));
   if(pvpEnded && g_pvpCount > 0)
      PvpCompute();

   //================================================================
   // MSS DETECTION
   //================================================================
   bool bearSeq = (PC(0) < PO(0)) && (PC(1) < PO(1));
   bool bullSeq = (PC(0) > PO(0)) && (PC(1) > PO(1));

   if(bearSeq)
   {
      g_trackedSh = MathMax(PH(2), PH(3));
      g_bearSeqSl = MathMin(PL(0), PL(1));
   }
   if(bullSeq)
   {
      g_trackedSl = MathMin(PL(2), PL(3));
      g_bullSeqSh = MathMax(PH(0), PH(1));
   }

   bool bullMss = IsSet(g_trackedSh) && PC(0) > g_trackedSh && PC(1) <= g_trackedSh;
   bool bearMss = IsSet(g_trackedSl) && PC(0) < g_trackedSl && PC(1) >= g_trackedSl;

   if(bullMss)
   {
      g_bullMssSl  = g_bearSeqSl;
      g_bullMssLvl = g_trackedSh;
      g_trackedSh  = EMPTY_VALUE;
      g_bearSeqSl  = EMPTY_VALUE;
      g_mssPendingLong  = true;
      g_mssPendingShort = false;
   }
   if(bearMss)
   {
      g_bearMssSl  = g_bullSeqSh;
      g_bearMssLvl = g_trackedSl;
      g_trackedSl  = EMPTY_VALUE;
      g_bullSeqSh  = EMPTY_VALUE;
      g_mssPendingShort = true;
      g_mssPendingLong  = false;
   }

   //================================================================
   // STRATEGY LOGIC
   //================================================================
   if(pvpStarted)
   {
      g_tradesToday   = 0;
      g_lastWasSl     = false;
      g_waitingLong   = false;
      g_waitingShort  = false;
      g_trackedSh     = EMPTY_VALUE;
      g_trackedSl     = EMPTY_VALUE;
      g_bearSeqSl     = EMPTY_VALUE;
      g_bullSeqSh     = EMPTY_VALUE;
      g_bullMssLvl    = EMPTY_VALUE;
      g_bearMssLvl    = EMPTY_VALUE;
      g_mssPendingLong  = false;
      g_mssPendingShort = false;
      CancelPending();
   }

   if(tradeEnded)
   {
      g_waitingLong  = false;
      g_waitingShort = false;
      CancelPending();
      if(HasOpenPosition())
         trade.PositionClose(g_posTicket);
   }

   bool tradeLimitOk = g_tradesToday < 2 && (g_tradesToday == 0 || (g_tradesToday == 1 && g_lastWasSl));
   bool canEnter = isEntry && !HasOpenPosition() && tradeLimitOk;

   bool longTrigger  = bullMss || (g_mssPendingLong  && !g_waitingLong  && IsSet(g_bullMssLvl) && PC(0) > g_bullMssLvl);
   bool shortTrigger = bearMss || (g_mssPendingShort && !g_waitingShort && IsSet(g_bearMssLvl) && PC(0) < g_bearMssLvl);

   bool longSetup  = canEnter && IsSet(g_vah) && PC(0) > g_vah && PC(0) > g_sessionVwap && longTrigger;
   bool shortSetup = canEnter && IsSet(g_val) && PC(0) < g_val && PC(0) < g_sessionVwap && shortTrigger;

   double point = _Point;
   double minDist = point * 10;

   if(longSetup && !g_waitingShort)
   {
      if(!g_waitingLong)
      {
         g_waitingLong = true;
         g_setupBarL   = g_barCounter;
         g_mssPendingLong = false;
      }
      g_retestLvlL = g_bullMssLvl;
      g_slLong     = IsSet(g_bullMssSl) ? g_bullMssSl : MathMin(PL(1), PL(2));
   }

   if(shortSetup && !g_waitingLong)
   {
      if(!g_waitingShort)
      {
         g_waitingShort = true;
         g_setupBarS    = g_barCounter;
         g_mssPendingShort = false;
      }
      g_retestLvlS = g_bearMssLvl;
      g_slShort    = IsSet(g_bearMssSl) ? g_bearMssSl : MathMax(PH(1), PH(2));
   }

   if(g_waitingLong && bearMss && IsSet(g_vah) && PC(0) < g_vah)
      g_waitingLong = false;
   if(g_waitingShort && bullMss && IsSet(g_val) && PC(0) > g_val)
      g_waitingShort = false;

   long barsL = g_barCounter - g_setupBarL;
   long barsS = g_barCounter - g_setupBarS;

   if(g_waitingLong && barsL >= 1)
   {
      double slDistL = MathMax(g_retestLvlL - g_slLong, minDist);
      if(barsL > 4 || PH(0) >= g_retestLvlL + slDistL || !isEntry)
         g_waitingLong = false;
   }
   if(g_waitingShort && barsS >= 1)
   {
      double slDistS = MathMax(g_slShort - g_retestLvlS, minDist);
      if(barsS > 4 || PL(0) <= g_retestLvlS - slDistS || !isEntry)
         g_waitingShort = false;
   }

   //--- Plaseaza / anuleaza ordinul limit de retest ---
   if(g_waitingLong && !HasOpenPosition() && isEntry)
      PlaceOrUpdateLimit(true);
   else if(g_pendingTicket != 0 && !g_waitingLong)
      CancelPending();

   if(g_waitingShort && !HasOpenPosition() && isEntry)
      PlaceOrUpdateLimit(false);
   else if(g_pendingTicket != 0 && !g_waitingShort)
      CancelPending();

   g_isPvpPrev   = isPvp;
   g_isTradePrev = isTrade;
}

//================================================================================
// Plaseaza ordinul BuyLimit/SellLimit de retest cu SL/TP atasat
//================================================================================
void PlaceOrUpdateLimit(bool isLong)
{
   if(g_pendingTicket != 0) return; // deja avem un ordin activ pentru acest setup

   double entryPrice = isLong ? g_retestLvlL : g_retestLvlS;
   double slPrice     = isLong ? g_slLong     : g_slShort;
   double point = _Point;
   double minDist = point * 10;

   double slDist = isLong ? MathMax(entryPrice - slPrice, minDist)
                           : MathMax(slPrice - entryPrice, minDist);
   double tpPrice = isLong ? entryPrice + slDist * InpRR
                            : entryPrice - slDist * InpRR;

   entryPrice = PriceRound(entryPrice);
   slPrice    = PriceRound(slPrice);
   tpPrice    = PriceRound(tpPrice);

   double lots = CalcLots(MathAbs(entryPrice - slPrice));
   if(lots <= 0) return;

   bool ok;
   if(isLong)
      ok = trade.BuyLimit(lots, entryPrice, _Symbol, slPrice, tpPrice, ORDER_TIME_GTC, 0, "Adiiva LONG retest");
   else
      ok = trade.SellLimit(lots, entryPrice, _Symbol, slPrice, tpPrice, ORDER_TIME_GTC, 0, "Adiiva SHORT retest");

   if(ok)
      g_pendingTicket = trade.ResultOrder();
}
