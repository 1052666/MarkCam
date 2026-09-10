#!/usr/bin/env python3
"""Draw a geometry review from actual native helper output. NOT a screenshot."""
import json,pathlib,html
ROOT=pathlib.Path(__file__).resolve().parents[1]
fixtures=json.loads((ROOT/'tests/layout-fixtures.json').read_text())
css='''body{background:#151719;color:white;font:15px -apple-system,sans-serif;margin:24px}h1{font-size:24px}p{color:#bbb;max-width:800px}main{display:flex;gap:30px;flex-wrap:wrap;align-items:flex-start}.case{width:375px}.phone{position:relative;background:black;overflow:hidden;outline:1px solid #555}.r{position:absolute;box-sizing:border-box;display:flex;align-items:center;justify-content:center;text-align:center;font-size:12px;color:#fff}.stage{background:linear-gradient(155deg,#497c81,#234b52 50%,#506b48 50%,#162e2c);overflow:hidden}.btn{background:#151617b8;border-radius:12px}.shutter{background:#fff;border:5px solid #aaa;border-radius:100%}.grid{position:absolute;inset:0;background:linear-gradient(90deg,transparent 33%,#ffffff20 33.1%,transparent 33.4%,transparent 66.6%,#ffffff20 66.7%,transparent 67%),linear-gradient(transparent 33%,#ffffff20 33.1%,transparent 33.4%,transparent 66.6%,#ffffff20 66.7%,transparent 67%)}.caption{margin:12px 0 20px;color:#bbb}'''
def box(k,r,text,cl='btn'):
 x,y,w,h=r;return f'<div class="r {cl}" style="left:{x}px;top:{y}px;width:{w}px;height:{h}px">{text}</div>'
sections=[]
for name in ['mini-photo-portrait','mini-video-portrait','SE-photo-portrait','mini-photo-landscape']:
 f=next(x for x in fixtures if x['name']==name);a=f['layout'];w,h=f['width'],f['height'];sx,sy,sw,sh=a['stage']
 content=f'<div class="phone" style="width:{w}px;height:{h}px">'
 content+=f'<div class="r stage" style="left:{sx}px;top:{sy}px;width:{sw}px;height:{sh}px"><div class="grid"></div><span style="font-size:30px">按真实比例显示<br>不拉伸、不裁切</span></div>'
 content+=box('hint',[sx+a['hint'][0],sy+a['hint'][1],a['hint'][2],a['hint'][3]],'系统流畅取景')
 for k,text in [('lenses','0.5×　　<span style="color:#ffd344">1×</span>　　2×'),('zoomLabel','1.0×'),('zoomSlider','━━━━━━●━━━━━━━━')]:
  r=a[k].copy();r[0]+=sx;r[1]+=sy;content+=box(k,r,text)
 for k,text in [('watermark','水印开'),('live','LIVE 关'),('settings','设置'),('mode','照片　　视频'),('files','待保存'),('flip','翻转'),('edit','水印 · 模板 · 调色')]:content+=box(k,a[k],text)
 content+=box('shutter',a['shutter'],'','shutter')+'</div>'
 sections.append(f'<section style="width:{w}px"><h2>{name}</h2>{content}<div class="caption">取景区域 {sw:.0f} × {sh:.0f} pt；画幅比 {sw/sh:.3f}</div></section>')
page='<!doctype html><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><title>MarkCam 1.1.1 layout review</title><style>'+css+'</style><h1>印记相机 1.1.1 · 布局检查</h1><p>这不是 App 截图：使用与 UIKit 相同 C 布局函数计算坐标的示意图，只检查空间关系。字体、真实相机画面和动态效果必须安装验证。</p><main>'+''.join(sections)+'</main>'
(ROOT/'docs/layout-review.html').write_text(page)
print(ROOT/'docs/layout-review.html')
