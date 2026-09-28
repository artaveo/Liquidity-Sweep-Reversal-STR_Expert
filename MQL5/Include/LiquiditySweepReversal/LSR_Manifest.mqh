//+------------------------------------------------------------------+
//| LSR_Manifest.mqh                                                 |
//| Exact Inputs record (Run Card) and run-output package writer     |
//| used by the DataManifest (roadmap 0A.6, Phase 1 Gate).           |
//+------------------------------------------------------------------+
#ifndef LSR_MANIFEST_MQH
#define LSR_MANIFEST_MQH

#include "LSR_Types.mqh"
#include "LSR_Json.mqh"

#define LSR_MANIFEST_SCHEMA_VERSION "lsr.datamanifest.v1"
#define LSR_OUTPUT_ROOT             "LSR"

//+------------------------------------------------------------------+
//| Every input with its value and roadmap default. Non-default      |
//| inputs are listed explicitly so the Run Card shows exactly what  |
//| changed and everything else stays at the roadmap default.        |
//+------------------------------------------------------------------+
class CLSR_InputRecorder
  {
private:
   string            m_name[];
   string            m_value[];
   string            m_default[];

public:
   void              Clear(void)
     {
      ArrayResize(m_name, 0);
      ArrayResize(m_value, 0);
      ArrayResize(m_default, 0);
     }
   void              Add(const string name, const string value, const string roadmapDefault)
     {
      int n = ArraySize(m_name);
      ArrayResize(m_name, n + 1);
      ArrayResize(m_value, n + 1);
      ArrayResize(m_default, n + 1);
      m_name[n] = name;
      m_value[n] = value;
      m_default[n] = roadmapDefault;
     }
   void              AddBool(const string name, const bool value, const bool roadmapDefault)
     { Add(name, value ? "true" : "false", roadmapDefault ? "true" : "false"); }
   void              AddNum(const string name, const double value, const double roadmapDefault)
     { Add(name, LSR_NumStr(value), LSR_NumStr(roadmapDefault)); }
   void              AddInt(const string name, const long value, const long roadmapDefault)
     { Add(name, IntegerToString(value), IntegerToString(roadmapDefault)); }

   int               NonDefaultCount(void) const
     {
      int c = 0;
      for(int i = 0; i < ArraySize(m_name); i++)
         if(m_value[i] != m_default[i])
            c++;
      return c;
     }

   void              WriteJson(CLSR_Json &j) const
     {
      j.BeginObject();
      j.KArr("inputs");
      for(int i = 0; i < ArraySize(m_name); i++)
        {
         j.BeginObject();
         j.KStr("name", m_name[i]);
         j.KStr("value", m_value[i]);
         j.KStr("roadmap_default", m_default[i]);
         j.KBool("is_default", m_value[i] == m_default[i]);
         j.EndObject();
        }
      j.EndArray();
      j.KArr("non_default_inputs");
      for(int i = 0; i < ArraySize(m_name); i++)
         if(m_value[i] != m_default[i])
            j.Str(m_name[i]);
      j.EndArray();
      j.EndObject();
     }

   string            RunCardText(void) const
     {
      string s = "# Exact Inputs — every input; non-default values are marked with *\n";
      for(int i = 0; i < ArraySize(m_name); i++)
         s += (m_value[i] != m_default[i] ? "* " : "  ") + m_name[i] + " = " + m_value[i] +
              (m_value[i] != m_default[i] ? "    (roadmap default: " + m_default[i] + ")" : "") + "\n";
      return s;
     }
  };

//+------------------------------------------------------------------+
//| Output folder Common\Files\LSR\<ExperimentId>\ with a checksum   |
//| index of every written file.                                     |
//+------------------------------------------------------------------+
class CLSR_RunOutput
  {
private:
   string            m_dir;
   string            m_files[];
   string            m_sha[];
   int               m_failures;

public:
   void              Init(const string experimentId)
     {
      m_dir = LSR_OUTPUT_ROOT + "\\" + experimentId + "\\";
      ArrayResize(m_files, 0);
      ArrayResize(m_sha, 0);
      m_failures = 0;
     }

   string            Dir(void) const { return m_dir; }
   int               Failures(void) const { return m_failures; }

   string            Write(const string fileName, const string text)
     {
      string sha = LSR_WriteUtf8File(m_dir + fileName, text, true);
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

//--- Experiment identifiers become folder names: letters, digits, '-', '_', '.'.
bool LSR_ValidateExperimentId(const string id, string &error)
  {
   error = "";
   int n = StringLen(id);
   if(n == 0 || n > 64)
     {
      error = "ExperimentId must be 1..64 characters";
      return false;
     }
   for(int i = 0; i < n; i++)
     {
      ushort c = StringGetCharacter(id, i);
      bool ok = (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || (c >= '0' && c <= '9') || c == '-' || c == '_' || c == '.';
      if(!ok)
        {
         error = "ExperimentId may contain only letters, digits, '-', '_' and '.'";
         return false;
        }
     }
   return true;
  }

#endif // LSR_MANIFEST_MQH
//+------------------------------------------------------------------+
