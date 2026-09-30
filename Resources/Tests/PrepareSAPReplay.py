from pathlib import Path
import sys

# Modify only the temporary diagnostic translation unit, never app sources.
source = Path('Asspp/Backend/AppStore/SAP/SapMachine.cpp').read_text()
random_call = 'SetResult(arc4random());'
time_call = 'auto now = std::chrono::system_clock::now();'
assert source.count(random_call) == 1 and source.count(time_call) == 1
source = source.replace(random_call, 'SetResult(SAPReplayRandom());')
source = source.replace(time_call, 'auto now = std::chrono::system_clock::time_point(std::chrono::milliseconds(SAPReplayTime()));')
open_call = 'UC_CHECK(uc_open(UC_ARCH_X86, UC_MODE_64, &m->uc_), "uc_open");'
assert source.count(open_call) == 1
source = source.replace(open_call, open_call + '''
    uc_hook replayTSC, replayTSCP;
    UC_CHECK(uc_hook_add(m->uc_, &replayTSC, UC_HOOK_INSN, reinterpret_cast<void *>(SAPReplayTimestamp), nullptr, 1, 0, UC_X86_INS_RDTSC), "fixture RDTSC hook");
    UC_CHECK(uc_hook_add(m->uc_, &replayTSCP, UC_HOOK_INSN, reinterpret_cast<void *>(SAPReplayTimestampP), nullptr, 1, 0, UC_X86_INS_RDTSCP), "fixture RDTSCP hook");
''')
source = '#include <cstdint>\n#include <unicorn/unicorn.h>\nuint32_t SAPReplayRandom();\nint64_t SAPReplayTime();\nbool SAPReplayTimestamp(uc_engine *, void *);\nbool SAPReplayTimestampP(uc_engine *, void *);\n' + source
Path(sys.argv[1]).write_text(source)
