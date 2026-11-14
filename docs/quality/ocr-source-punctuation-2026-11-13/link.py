from pathlib import Path
import subprocess,sys
r=Path('/private/tmp/vauldy-ocr-final-20261113');b=r/'source/.build/release'
objects=[str(p) for target in ['VauldyCore','VauldyDocumentCore','VauldyDocumentIntelligence'] for p in (b/(target+'.build')).glob('*.o')]
subprocess.run(['swiftc','-O','-parse-as-library','-module-cache-path',str(r/'module-cache'),'-I',str(b/'Modules'),sys.argv[1],*sys.argv[3:],*objects,'-o',sys.argv[2]],check=True)
