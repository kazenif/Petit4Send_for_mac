import dnfile
from dncil.cil.body.reader import read_method_body_from_bytes
from dncil.clr.token import Token
p=dnfile.dnPE('Petit4Send.exe')
def resolve(t):
 if not isinstance(t,Token): return str(t)
 if t.table==0x70: return repr(p.net.user_strings.get(t.rid).value)
 table=p.net.mdtables.tables.get(t.table)
 if table and t.rid:
  row=table.rows[t.rid-1]
  return str(getattr(row,'Name',getattr(row,'TypeName',t)))
 return str(t)
import sys
for arg in sys.argv[1:]:
 m=p.net.mdtables.MethodDef.rows[int(arg)-1]
 print('\nMETHOD',arg,m.Name)
 body=read_method_body_from_bytes(p.get_data(m.Rva,16000))
 for i in body.instructions: print(f'{i.offset:04x} {i.opcode.name:14} {resolve(i.operand)}')
