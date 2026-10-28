//+------------------------------------------------------------------+
//| OB + Liquidity Sweep + CISD + LTF BOS EA (MT5)                  |
//| Test on a DEMO account first.                                   |
//+------------------------------------------------------------------+
#property strict
#property version   "1.00"
#property description "H1 Order Block + liquidity sweep, LTF CISD/BOS, RR 1:5"

#include <Trade/Trade.mqh>
CTrade trade;

input double FixedLot             = 0.01;
input double RiskReward           = 5.0;
input ENUM_TIMEFRAMES EntryTF     = PERIOD_M5;
input int    H1Lookback           = 20;
input int    SwingLookback        = 8;
input int    MaxSetupAgeH1Bars    = 12;
input int    MaxSpreadPoints      = 0;
input ulong  MagicNumber          = 28102026;
input int    SlippagePoints       = 20;
input bool   OnePositionPerSymbol = true;

struct OBSetup
{
   bool valid;
   bool bullish;
   datetime created;
   double low;
   double high;
};

OBSetup setup;
datetime lastH1Bar = 0;
datetime lastEntryBar = 0;

double NPrice(double p)
{
   return NormalizeDouble(p,(int)SymbolInfoInteger(_Symbol,SYMBOL_DIGITS));
}

bool NewBar(ENUM_TIMEFRAMES tf,datetime &stored)
{
   datetime t=iTime(_Symbol,tf,0);
   if(t==0 || t==stored) return false;
   stored=t;
   return true;
}

bool HasOurPositionOrOrder()
{
   if(!OnePositionPerSymbol) return false;

   for(int i=PositionsTotal()-1;i>=0;--i)
   {
      ulong ticket=PositionGetTicket(i);
      if(ticket>0 &&
         PositionGetString(POSITION_SYMBOL)==_Symbol &&
         (ulong)PositionGetInteger(POSITION_MAGIC)==MagicNumber)
         return true;
   }

   for(int j=OrdersTotal()-1;j>=0;--j)
   {
      ulong ticket=OrderGetTicket(j);
      if(ticket>0 &&
         OrderGetString(ORDER_SYMBOL)==_Symbol &&
         (ulong)OrderGetInteger(ORDER_MAGIC)==MagicNumber)
         return true;
   }

   return false;
}

bool SpreadOK()
{
   if(MaxSpreadPoints<=0) return true;

   double ask=SymbolInfoDouble(_Symbol,SYMBOL_ASK);
   double bid=SymbolInfoDouble(_Symbol,SYMBOL_BID);

   return ((ask-bid)/_Point<=MaxSpreadPoints);
}

// البحث التقريبي عن الأوردر بلوك على فريم الساعة
void FindH1OrderBlock()
{
   setup.valid=false;

   MqlRates r[];
   ArraySetAsSeries(r,true);

   int need=MathMax(H1Lookback+10,40);
   if(CopyRates(_Symbol,PERIOD_H1,0,need,r)<need) return;

   for(int s=3;s<=MaxSetupAgeH1Bars+2;++s)
   {
      double priorHigh=r[s+1].high;
      double priorLow=r[s+1].low;

      for(int k=s+2;k<=s+SwingLookback;++k)
      {
         priorHigh=MathMax(priorHigh,r[k].high);
         priorLow=MathMin(priorLow,r[k].low);
      }

      bool sweepLow=(r[s].low<priorLow &&
                     r[s].close>priorLow);

      bool sweepHigh=(r[s].high>priorHigh &&
                      r[s].close<priorHigh);

      bool bullishBOS=false;
      bool bearishBOS=false;

      for(int j=s-1;j>=1;--j)
      {
         if(r[j].close>priorHigh) bullishBOS=true;
         if(r[j].close<priorLow) bearishBOS=true;
      }

      bool bull=sweepLow && bullishBOS;
      bool bear=sweepHigh && bearishBOS;

      if(!bull && !bear) continue;

      int obIndex=-1;

      for(int c=s+1;c<=s+6 && c<need;++c)
      {
         if(bull && r[c].close<r[c].open)
         {
            obIndex=c;
            break;
         }

         if(bear && r[c].close>r[c].open)
         {
            obIndex=c;
            break;
         }
      }

      if(obIndex<0) continue;

      setup.valid=true;
      setup.bullish=bull;
      setup.created=r[s].time;
      setup.low=r[obIndex].low;
      setup.high=r[obIndex].high;

      return;
   }
}

bool PriceInsideOB()
{
   if(!setup.valid) return false;

   double bid=SymbolInfoDouble(_Symbol,SYMBOL_BID);
   double ask=SymbolInfoDouble(_Symbol,SYMBOL_ASK);
   double p=setup.bullish ? bid : ask;

   return (p>=setup.low && p<=setup.high);
}

// تأكيد تقريبي لحركة CISD
bool GetCISDEntry(double &entry,double &sl,
                  double &tp,bool &isBuy)
{
   MqlRates x[];
   ArraySetAsSeries(x,true);

   if(CopyRates(_Symbol,EntryTF,0,10,x)<10)
      return false;

   bool bullCISD=(x[1].close>x[1].open &&
                  x[1].close>x[2].high);

   bool bearCISD=(x[1].close<x[1].open &&
                  x[1].close<x[2].low);

   if(setup.bullish && bullCISD && PriceInsideOB())
   {
      isBuy=true;
      entry=NPrice(x[1].high);
      sl=NPrice(setup.low-2*_Point);

      if(entry<=sl) return false;

      tp=NPrice(entry+(entry-sl)*RiskReward);
      return true;
   }

   if(!setup.bullish && bearCISD && PriceInsideOB())
   {
      isBuy=false;
      entry=NPrice(x[1].low);
      sl=NPrice(setup.high+2*_Point);

      if(entry>=sl) return false;

      tp=NPrice(entry-(sl-entry)*RiskReward);
      return true;
   }

   return false;
}

// وضع أمر شراء أو بيع معلّق
bool PlacePending(bool isBuy,double entry,double sl,double tp)
{
   double ask=SymbolInfoDouble(_Symbol,SYMBOL_ASK);
   double bid=SymbolInfoDouble(_Symbol,SYMBOL_BID);

   int stopsLevel=(int)SymbolInfoInteger(
      _Symbol,SYMBOL_TRADE_STOPS_LEVEL);

   double minDist=stopsLevel*_Point;

   trade.SetExpertMagicNumber(MagicNumber);
   trade.SetDeviationInPoints(SlippagePoints);

   bool ok=false;

   if(isBuy)
   {
      if(entry<=ask+minDist) return false;

      ok=trade.BuyStop(
         FixedLot,entry,_Symbol,sl,tp,
         ORDER_TIME_GTC,0,"OB-CISD RR5 Buy");
   }
   else
   {
      if(entry>=bid-minDist) return false;

      ok=trade.SellStop(
         FixedLot,entry,_Symbol,sl,tp,
         ORDER_TIME_GTC,0,"OB-CISD RR5 Sell");
   }

   if(!ok)
   {
      Print("Pending order failed: ",
            trade.ResultRetcode()," - ",
            trade.ResultRetcodeDescription());
   }

   return ok;
}

int OnInit()
{
   setup.valid=false;
   trade.SetExpertMagicNumber(MagicNumber);

   Print("OB-CISD RR5 EA started on ",_Symbol,
         ". Verify on demo first.");

   return INIT_SUCCEEDED;
}

void OnTick()
{
   if(!SpreadOK()) return;

   if(NewBar(PERIOD_H1,lastH1Bar))
      FindH1OrderBlock();

   if(!setup.valid) return;
   if(HasOurPositionOrOrder()) return;
   if(!NewBar(EntryTF,lastEntryBar)) return;

   double entry=0,sl=0,tp=0;
   bool isBuy=false;

   if(GetCISDEntry(entry,sl,tp,isBuy))
      PlacePending(isBuy,entry,sl,tp);
}
//+------------------------------------------------------------------+
