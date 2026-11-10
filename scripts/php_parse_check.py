from tree_sitter import Language, Parser
import tree_sitter_php as tsphp
import sys
parser=Parser(Language(tsphp.language_php()))
files=sys.argv[1:]
bad=0
for f in files:
    data=open(f,'rb').read(); tree=parser.parse(data)
    errs=[]; stack=[tree.root_node]
    while stack:
        n=stack.pop()
        if n.type=='ERROR' or n.is_missing: errs.append((n.start_point,n.type))
        stack.extend(n.children)
    print(('OK ' if not errs else 'ERR ')+f+(' errors='+str(len(errs)) if errs else ''))
    bad += 1 if errs else 0
sys.exit(1 if bad else 0)
