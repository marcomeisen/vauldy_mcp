from PIL import Image,ImageOps,ImageFilter
import numpy as np
from pathlib import Path
r=Path('/private/tmp/vauldy-ocr-final-20261113');out=r/'probe-faint';out.mkdir(exist_ok=True)
src=Path('/private/tmp/vauldy-ocr-numeric-20261113/final-faint')
def mean(a,k):
 p=np.pad(a,k,mode='reflect');result=np.zeros_like(a)
 for y in range(k*2+1):
  for x in range(k*2+1):result+=p[y:y+a.shape[0],x:x+a.shape[1]]
 return result/(k*2+1)**2
def nlm(a,h,patch):
 sigma=np.std(a[:6]);s=np.zeros_like(a);w=np.zeros_like(a);p=np.pad(a,7,mode='reflect')
 for dy in range(-7,8):
  for dx in range(-7,8):
   b=p[7+dy:7+dy+a.shape[0],7+dx:7+dx+a.shape[1]]
   distance=mean((a-b)**2,patch)
   weight=np.exp(-np.maximum(distance-2*sigma*sigma,0)/(h*h))
   s+=weight*b;w+=weight
 return s/w
for name in ['grid-13-88-15','grid-9-93-25']:
 for row,box in enumerate([(40,93,315,129),(40,138,315,174)]):
  im=Image.open(src/(name+'.png')).convert('L').crop(box);orig=np.asarray(im).astype(float)
  for mode in ['raw','blur03','blur06','nlm4','nlm7','nlm10','nlm14']:
   a=orig if mode=='raw' else np.asarray(im.filter(ImageFilter.GaussianBlur(float(mode[-2:])/10))).astype(float) if mode.startswith('blur') else nlm(orig,int(mode[3:]),1)
   for white in ['floor','mean']:
    border=np.concatenate([a[:5,:].ravel(),a[-5:,:].ravel()]);low=np.percentile(a,2);high=np.percentile(border,2 if white=='floor' else 50)
    b=np.clip((a-low)*255/max(1,high-low),0,255).astype('uint8');c=Image.fromarray(b);c=c.resize((c.width*4,c.height*4),Image.Resampling.LANCZOS);c=ImageOps.expand(c,30,255);c.save(out/f'{name}-{row}-{mode}-{white}.png')
print('Prepared',len(list(out.glob('*.png'))),'source-only denoising probes')
