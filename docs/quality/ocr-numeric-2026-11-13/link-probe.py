from pathlib import Path
import subprocess
r=Path('/private/tmp/vauldy-ocr-numeric-20261113');b=r/'source/.build/release'
objects=[str(p) for target in ['VauldyCore','VauldyDocumentCore','VauldyDocumentIntelligence'] for p in (b/(target+'.build')).glob('*.o')]
subprocess.run(['swiftc','-O','-parse-as-library','-module-cache-path',str(r/'module-cache'),'-I',str(b/'Modules'),str(r/'NumericPDFProbe.swift'),*objects,'-o',str(r/'pdf-probe')],check=True)
