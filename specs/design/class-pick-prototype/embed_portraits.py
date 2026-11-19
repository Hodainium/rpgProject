import json,base64,io,glob,os
from PIL import Image
d={}
for f in glob.glob('presentation/demo/cards/portraits/*.png'):
    im=Image.open(f).convert('RGB').resize((300,300),Image.LANCZOS)
    b=io.BytesIO(); im.save(b,'JPEG',quality=80)
    d[os.path.basename(f).split('.')[2]]='data:image/jpeg;base64,'+base64.b64encode(b.getvalue()).decode()
SKIP={'Ult Charge','Ult Charge Hit','Break Physical','Break Fire','Break Ice','Block','Sp Gain'}
cl=json.load(open(os.environ['TEMP']+'/classes.json'))
for c in cl:
    c['img']=d[c['id']]
    c['abilities']=[{'n':a[0],'t':(a[1][0].split('.')[-1] if a[1] else 'Skill')} for a in c['abilities'] if a[0] not in SKIP]
    c['color']='#%02x%02x%02x'%tuple(int(x*255) for x in c['color'][:3])
json.dump(cl,open(os.environ['TEMP']+'/classes_full.json','w'))
print(sum(len(v) for v in d.values()), [ (c['name'],c['core'],[a['n']+':'+a['t'] for a in c['abilities']]) for c in cl])
