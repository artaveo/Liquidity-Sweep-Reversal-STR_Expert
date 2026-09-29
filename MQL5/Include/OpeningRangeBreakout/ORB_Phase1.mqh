//+------------------------------------------------------------------+
//| ORB_Phase1.mqh                                                   |
//| Opening Range Breakout — umbrella include (roadmap 1.2).         |
//| Reuses the LSR Phase 1 contract and bar builder unchanged.       |
//+------------------------------------------------------------------+
#ifndef ORB_PHASE1_MQH
#define ORB_PHASE1_MQH

#include "../LiquiditySweepReversal/LSR_Phase1.mqh"
#include "../LiquiditySweepReversal/LSR_Bars.mqh"
#include "ORB_Types.mqh"
#include "ORB_Days.mqh"
#include "ORB_Proxy.mqh"

//+------------------------------------------------------------------+
//| Run package folder Common\Files\ORB\<ExperimentId>\ (roadmap 10).|
//| Same contract as CLSR_RunOutput, which hard-codes the LSR root.  |
//+------------------------------------------------------------------+
class CORB_RunOutput
  {
private:
   string            m_dir;
   string            m_files[];
   string            m_sha[];
   int               m_failures;

   string            Index(const string fileName, const string sha)
     {
      if(sha == "")
        {
         m_failures++;
         return "";
        }
      for(int i = 0; i < ArraySize(m_files); i++)
         if(m_files[i] == fileName)
           {
            m_sha[i] = sha;
            return sha;
           }
      int n = ArraySize(m_files);
      ArrayResize(m_files, n + 1);
      ArrayResize(m_sha, n + 1);
      m_files[n] = fileName;
      m_sha[n] = sha;
      return sha;
     }

public:
   void              Init(const string experimentId)
     {
      m_dir = ORB_OUTPUT_ROOT + "\\" + experimentId + "\\";
      ArrayResize(m_files, 0);
      ArrayResize(m_sha, 0);
      m_failures = 0;
     }
   string            Dir(void) const { return m_dir; }
   int               Failures(void) const { return m_failures; }
   string            Write(const string fileName, const string text) { return Index(fileName, LSR_WriteUtf8File(m_dir + fileName, text, true)); }

   //--- Indexes a file written directly (streamed ledgers) by hashing it from disk.
   string            RegisterFile(const string fileName)
     {
      string sha = "";
      int h = FileOpen(m_dir + fileName, FILE_READ | FILE_BIN | FILE_COMMON);
      if(h != INVALID_HANDLE)
        {
         uchar data[], key[], hash[];
         ulong size = FileSize(h);
         if(size > 0)
            FileReadArray(h, data, 0, (int)size);
         FileClose(h);
         if(CryptEncode(CRYPT_HASH_SHA256, data, key, hash) > 0)
            sha = LSR_HexLower(hash);
        }
      return Index(fileName, sha);
     }

   void              WriteIndexJson(CLSR_Json &j) const
     {
      j.BeginArray();
      for(int i = 0; i < ArraySize(m_files); i++)
        {
         j.BeginObject();
         j.KStr("file", m_files[i]);
         j.KStr("sha256", m_sha[i]);
         j.EndObject();
        }
      j.EndArray();
     }
  };

#endif // ORB_PHASE1_MQH
//+------------------------------------------------------------------+
