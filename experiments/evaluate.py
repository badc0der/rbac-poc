import pandas as pd, sys, json
from pathlib import Path
def main(out):
    rd=pd.read_csv(Path(out)/"rules_decisions.csv")
    md=pd.read_csv(Path(out)/"model_decisions.csv")
    tp_rules=sum(rd.rule_id!=-1); fp_rules=sum((rd.rule_id!=-1)&(rd['features'].str.contains('"Is Encrypted?": 0')))
    tp_model=sum(md.prob>=0.7); fp_model=sum((md.prob>=0.7)&(md['features'].str.contains('"Is Encrypted?": 0')))
    with open(Path(out)/"summary.txt","w") as fh:
        fh.write(json.dumps({"tp_rules":int(tp_rules),"fp_rules":int(fp_rules),
                             "tp_model":int(tp_model),"fp_model":int(fp_model)},indent=2))
if __name__=="__main__": main(sys.argv[1])

