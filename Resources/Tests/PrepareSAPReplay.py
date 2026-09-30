from pathlib import Path
import sys

# Modify only the temporary diagnostic translation unit, never app sources.
source = Path('Asspp/Backend/AppStore/SAP/SapMachine.cpp').read_text()
random_call = 'SetResult(arc4random());'
time_call = 'auto now = std::chrono::system_clock::now();'
assert source.count(random_call) == 1 and source.count(time_call) == 1
source = source.replace(random_call, 'SetResult(SAPReplayRandom());')
source = source.replace(time_call, 'auto now = std::chrono::system_clock::time_point(std::chrono::milliseconds(SAPReplayTime()));')
source = '#include <cstdint>\nuint32_t SAPReplayRandom();\nint64_t SAPReplayTime();\n' + source
Path(sys.argv[1]).write_text(source)
