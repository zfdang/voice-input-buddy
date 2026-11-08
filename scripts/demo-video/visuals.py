from PIL import Image, ImageDraw, ImageFont
import math, re
W,H,FPS=1920,1080,12
FONT='/System/Library/Fonts/STHeiti Medium.ttc'
fonts={}
def get_font(size):
 if size not in fonts:
  fonts[size]=ImageFont.truetype(FONT,size)
 return fonts[size]

BLUE='#3268DA'; INK='#253449'; GREEN='#35AB84'; ORANGE='#EF9C4C'; BG='#FFF9EF'; LINE='#DCE3EE'
scenes=[
 ('遥控搭子', '打破人与 AI 之间的沟通带宽瓶颈', ['大模型时代，编码范式变迁', '键盘打字 100 WPM vs 思维语音 300+ WPM', '动口不行动手，与 AI 同频思考'], ''),
 ('破局：身边的廉价硬件', '拒绝昂贵 AI 硬件，唤醒闲置电视遥控器', ['市面专用 AI 硬件动辄数百上千元', '电视遥控器：工业级微动、实体盲操按键', '两节干电池供电，超长数月续航'], ''),
 ('Remote Buddy · 遥控搭子', '让电视遥控器秒变 Mac 语音输入神器', ['专为 macOS 打造的系统级桥接工具', '拿起遥控器，按住说话，松手即上屏', '完全开源 · 零音频留存 · 零隐私泄漏'], ''),
 ('它是怎样工作的？', '不跑大模型，专心做最稳定的驱动级桥梁', ['遥控器：蓝牙压缩音频与物理按键', '遥控搭子：实时 ADPCM 解码与快捷键注入', '输入工具：转写文字并写入当前光标'], ''),
 ('01  一站式免配置安装', '一个安装包，搞定 App 与虚拟麦克风驱动', ['前往 remote.zfdang.com 下载安装包', '底层打上 USB 伪装，全系统即插即用', '支持 Apple Silicon 与 Intel Mac'], ''),
 ('02  权限与安全底线', '跟随向导透明授权，坚守纯本地隐私', ['蓝牙、输入监控与辅助功能权限透明指引', '零音频保留：纯内存流转，绝不落盘', '零网络遥测：不上传数据，密码框自动防护'], ''),
 ('03  多硬件兼容', '支持小米系列与 Google Chromecast 遥控器', ['小米电视遥控器 2 / 2 Pro (RC001 / RC003)', 'Google Chromecast 语音遥控器 (G9N9N)', '独立设备增益调节，音量自动自愈'], ''),
 ('04  输入工具生态', '支持各类主流输入法与离线本地模型', ['微信输入法（深度优化）、豆包输入法、网易叭哥说', 'Typeless、VoiceCursor 独立悬浮工具', 'macOS 原生听写与本地离线 Whisper'], ''),
 ('05  按键映射与常用语', '不仅是语音键，更是桌面效率宏手柄', ['全量按键自定义：单击、双击、长按分别设置', '常用语功能：Prompt 模板与代码片段一键直出', '方向键、确认键、返回键自由映射系统动作'], ''),
 ('试一试：按住，说话，松开', '光标所至，行云流水', ['点击任意文本框：Cursor / VSCode / 终端', '按住语音键说话：“把这段逻辑重构为异步并发”', '松开按键，代码指令整齐落定，心流无缝'], ''),
 ('极客之选，即刻体验', 'remote.zfdang.com', ['完全开源：基于 GPL-3.0 协议发布', '前往官网 remote.zfdang.com 下载体验', '翻出抽屉里的遥控器，开启全新输入体验！'], ''),
]

def text(d,xy,t,size=36,fill=INK): d.text(xy,t,font=get_font(size),fill=fill)
def rr(d,box,fill,r=28,outline=None,width=2): d.rounded_rectangle(box,radius=r,fill=fill,outline=outline,width=width)
def center(d,x,y,t,size=36,color=INK):
 b=d.textbbox((0,0),t,font=get_font(size)); text(d,(x-(b[2]-b[0])/2,y),t,size,color)
def wrap(d,t,size,maxw):
 lines=[]; s=''
 for c in t:
  if d.textlength(s+c,font=get_font(size))>maxw: lines.append(s);s=c
  else:s+=c
 if s:lines.append(s)
 return lines

def character(d,x,y,t):
 # Friendly cartoon operator, drawn directly for this animation.
 bob=math.sin(t*2.4)*4
 y+=bob
 d.ellipse((x-92,y-78,x+92,y+114),fill='#E6BE98',outline=INK,width=4)
 d.pieslice((x-94,y-100,x+94,y+73),180,360,fill='#364358')
 d.ellipse((x-51,y+1,x-35,y+22),fill=INK);d.ellipse((x+32,y+1,x+48,y+22),fill=INK)
 d.ellipse((x-77,y+40,x-49,y+52),fill='#E8998D');d.ellipse((x+48,y+40,x+76,y+52),fill='#E8998D')
 d.arc((x-29,y+18,x+29,y+64),5,175,fill=INK,width=5)
 rr(d,(x-122,y+112,x+122,y+320),BLUE,60)
 d.line((x-84,y+170,x-150,y+232),fill='#E6BE98',width=36)
 d.line((x+82,y+170,x+156,y+112),fill='#E6BE98',width=36)
 d.ellipse((x+130,y+88,x+174,y+131),fill='#E6BE98',outline=INK,width=3)
 center(d,x,y+165,'RB',48,'white')

def remote(d,x,y,t,active=False,scale=1):
 rw,rh=int(112*scale),int(310*scale)
 if scale != 1:
  layer=Image.new('RGBA',(112,310),(0,0,0,0))
  remote(ImageDraw.Draw(layer),0,0,t,active,1)
  layer=layer.resize((rw,rh),Image.Resampling.LANCZOS)
  d._image.paste(layer,(int(x),int(y)),layer)
  return
 rr(d,(x,y,x+rw,y+rh),'#344256',30)
 for px in [.31,.70]: d.ellipse((x+rw*px-10,y+28,x+rw*px+10,y+48),fill='#647489')
 if active:
  d.ellipse((x+rw*.70-16,y+22,x+rw*.70+16,y+54),outline=GREEN,width=5)
 d.ellipse((x+rw*.18,y+65,x+rw*.82,y+139),fill='#1F2C40')
 d.ellipse((x+rw*.38,y+89,x+rw*.62,y+114),fill='#728296')
 for row in range(3):
  for px in [.32,.68]:d.ellipse((x+rw*px-10,y+161+row*39,x+rw*px+10,y+181+row*39),fill='#728296')
 center(d,x+rw/2,y+rh-26,'RB',24,'#AAB8CA')

def window(d,selected,t):
 rr(d,(960,236,1780,836),'white',30,LINE,3)
 rr(d,(960,236,1780,287),'#E9EFF8',26)
 for i,c in enumerate(['#F57E73','#F3C264','#81CFA5']):d.ellipse((984+i*28,252,999+i*28,267),fill=c)
 center(d,1370,249,'遥控搭子',24)
 rr(d,(960,288,1120,836),'#F2F6FD',12)
 nav=['设备连接','按键映射','常用语','输入法集成','权限与环境','设置']
 for j,n in enumerate(nav):
  yy=310+j*82
  if j==selected:rr(d,(973,yy-10,1106,yy+50),'#DCE9FF',12)
  center(d,1040,yy,n,24,BLUE if j==selected else '#7A869A')
 return 1160,316

total_duration = 199.0
voice_lengths=[]

def frame(i,u,total):
 im=Image.new('RGB',(W,H),BG);d=ImageDraw.Draw(im)
 for j in range(5):
  xx=1500+j*90; yy=90+math.sin(u*.4+j)*18
  d.ellipse((xx,yy,xx+28,yy+28),fill='#E1EBFA')
 text(d,(92,43),'REMOTE BUDDY  /  遥控搭子',28,BLUE)
 text(d,(92,112),scenes[i][0],64)
 text(d,(94,198),scenes[i][1],32,'#758398')
 rr(d,(92,282,860,835),'#EDF3FC',36)
 character(d,270,450,u)
 for j,line in enumerate(scenes[i][2]):
  yy=329+j*113
  if u>j*.65:
   d.ellipse((440,yy+2,478,yy+40),fill=GREEN)
   center(d,459,yy+3,str(j+1),28,'white')
   ls=wrap(d,line,32,335)
   for k,l in enumerate(ls):text(d,(497,yy+k*41),l,32)

 if i==0:
  rr(d,(1000,320,1740,760),'white',32,LINE)
  center(d,1370,365,'打字速度 vs 语音速度',38,BLUE)
  rr(d,(1060,430,1680,540),'#FFF2F0',18)
  text(d,(1085,450),'传统键盘打字：~60-100 WPM',28,'#D9363E')
  text(d,(1085,490),'机械输入慢、频繁打断思路、手指疲惫',22,'#758398')
  rr(d,(1060,570,1680,680),'#F0F9EB',18)
  text(d,(1085,590),'自然语音沟通：~300+ WPM',28,'#389E0D')
  text(d,(1085,630),'与脑海思维同频、零摩擦、大模型吞吐倍增',22,'#758398')
 elif i==1:
  rr(d,(1000,310,1740,780),'white',32,LINE)
  center(d,1370,350,'硬件破局：电视蓝牙遥控器',38,BLUE)
  rr(d,(1060,420,1680,530),'#F4F7FD',18)
  text(d,(1085,440),'市面专用 AI 硬件：¥500~¥1500+',26,INK)
  text(d,(1085,480),'锂电池频繁充电 · 强制绑定按月订阅',22,'#758398')
  rr(d,(1060,550,1680,720),'#EDF8F2',18)
  text(d,(1085,570),'电视蓝牙遥控器：¥60~¥70 / $10~$15',28,GREEN)
  text(d,(1085,615),'• 实体微动语音按键，盲按极准',24,INK)
  text(d,(1085,655),'• 两节 7 号电池，超长数月续航',24,INK)
 elif i==2:
  remote(d,1050,340,u,2<u<8,1.4)
  rr(d,(1270,360,1760,700),'white',30,LINE)
  center(d,1515,415,'Remote Buddy',44,BLUE)
  center(d,1515,480,'遥控搭子',36)
  center(d,1515,560,'按住说话 · 松手结束',32,GREEN)
  center(d,1515,620,'文字瞬间落在当前光标处',24,'#758398')
 elif i==3:
  labels=['遥控器','遥控搭子','输入工具']
  for j,l in enumerate(labels):
   xx=930+j*293
   rr(d,(xx,421,xx+255,646),'white',26,LINE)
   center(d,xx+127,456,['声音','连接桥梁','文字'][j],48,BLUE)
   center(d,xx+127,553,l,32)
   if j<2:
    d.line((xx+260,527,xx+288,527),fill=GREEN,width=6)
  pos=930+(u%3)/3*840;d.ellipse((pos,704,pos+24,728),fill=GREEN)
 elif i==4:
  rr(d,(1030,317,1740,763),'white',36,LINE)
  center(d,1385,365,'Remote_Buddy.pkg',40,BLUE)
  for j,l in enumerate(['Remote Buddy.app','虚拟麦克风驱动 (免驱伪装)']):
   rr(d,(1100,450+j*105,1670,527+j*105),'#EDF3FC',18)
   center(d,1385,467+j*105,l,32)
  center(d,1385,683,'一个安装包，完成两项安装',28)
 elif i==5:
  x,y=window(d,4,u)
  text(d,(x,y),'系统权限与本地隐私',40)
  for j,l in enumerate(['蓝牙权限','输入监控','辅助功能']):
   yy=y+70+j*93;rr(d,(x,yy,1734,yy+77),'#F2F6FD',16)
   text(d,(x+15,yy+24),l,28)
   ready=u>2+j*2
   d.ellipse((x+175,yy+32,x+187,yy+44),fill=GREEN if ready else ORANGE)
   text(d,(x+195,yy+25),'已开启' if ready else '未开启',24)
   rr(d,(x+330,yy+20,1714,yy+58),'#E0E5ED',10)
   center(d,x+441,yy+25,'打开蓝牙设置' if j==0 else '打开系统设置',24)
  rr(d,(x,y+364,1734,y+469),'#EDF8F2',16)
  text(d,(x+15,y+377),'100% 本地运行 · 零音频留存 · 零隐私上报',26,GREEN)
  text(d,(x+15,y+425),'遇到密码框自动静默降级防护',22,'#758398')
 elif i==6:
  x,y=window(d,0,u)
  rr(d,(1140,314,1390,795),'#F2F6FD',18)
  center(d,1265,339,'小米 / Chromecast',24)
  center(d,1265,384,'正在连接…' if u<4 else '已连接',28,GREEN)
  remote(d,1210,435,u,False,.9)
  rr(d,(1410,314,1754,616),'#F2F6FD',18)
  text(d,(1430,340),'硬件适配支持',32)
  text(d,(1430,405),'• 小米遥控器 2 / 2 Pro',24)
  text(d,(1430,445),'• Chromecast G9N9N',24)
  text(d,(1430,490),'设备独立增益调节',26)
  d.line((1435,536,1715,536),fill=LINE,width=7)
  d.ellipse((1530,522,1558,550),fill=BLUE)
  text(d,(1430,575),'按向导快速完成测试',24,BLUE)
  center(d,1578,706,'连接后测试按键',28,GREEN)
 elif i==7:
  x,y=window(d,3,u)
  text(d,(x,y),'输入法与语音工具集成',32)
  rr(d,(x,y+56,1735,y+167),'#EDF3FC',18)
  text(d,(x+16,y+70),'输入工具生态自由搭配',28,BLUE)
  text(d,(x+16,y+119),'语音麦克风：Remote Buddy Mic',24)
  for j,label in enumerate(['微信输入法','豆包输入法','网易叭哥说','Typeless','VoiceCursor','本地离线 Whisper']):
   xx=x+(j%2)*294;yy=y+184+(j//2)*82
   rr(d,(xx,yy,xx+280,yy+73),'#DCE9FF' if j==0 else '#F2F6FD',12)
   text(d,(xx+12,yy+5),label,24,BLUE if j==0 else INK)
   text(d,(xx+12,yy+39),'通过向导配置并测试',24)
   if j==0:d.ellipse((xx+249,yy+12,xx+263,yy+26),fill=BLUE)
  text(d,(x,y+439),'语音触发方式：按住说话 / 点按开关',24,BLUE)
 elif i==8:
  x,y=window(d,1,u)
  text(d,(1140,311),'按键映射与常用语',32)
  text(d,(1450,319),'自定义宏',24)
  rr(d,(1556,318,1612,345),GREEN,14)
  d.ellipse((1585,321,1608,342),fill='white')
  rr(d,(1140,367,1750,409),'#F2F6FD',10)
  text(d,(1155,374),'支持映射系统快捷键与 Prompt 常用语模板',22,BLUE)
  remote(d,1386,430,u,False,.84)
  for j,(label,action,xx,yy) in enumerate([
   ('电源键','Escape',1140,430),('上键','↑',1140,530),
   ('返回键','删除/撤销',1140,630),('语音键','语音触发',1505,430),
   ('确定键','Tab/采纳',1505,530),('下键','↓',1505,630)]):
   rr(d,(xx,yy,xx+230,yy+88),'#DCE9FF' if label=='确定键' else '#F2F6FD',12)
   text(d,(xx+10,yy+7),label,24)
   if label=='语音键':
    text(d,(xx+10,yy+45),'按住说话 / 松手结束',20,BLUE)
   else:
    for k,gesture in enumerate(['单击','双击','长按']):
     center(d,xx+40+k*75,yy+36,gesture,20,'#758398')
     center(d,xx+40+k*75,yy+61,action if k==0 else '常用语',18)
  rr(d,(1140,735,1750,815),'#EDF3FC',14)
  text(d,(1160,748),'常用语功能：预设 Prompt / 代码片段，按键一键直达上屏',22,BLUE)
  text(d,(1160,780),'支持单击、双击、长按独立触发，无需键盘反复敲击',19,'#758398')
 elif i==9:
  rr(d,(955,306,1790,817),'white',30,LINE)
  text(d,(1000,345),'文本输入框 · 示意 (Cursor / VSCode / 终端)',30)
  rr(d,(996,410,1748,605),'#F4F7FD',18)
  phrase='把这段逻辑重构为异步并发，并增加测试。'
  if u>=7:
   n=min(len(phrase),int((u-7)*10)+1);text(d,(1025,478),phrase[:n],38)
  else:
   text(d,(1025,478),'请按住遥控器语音键说话…',38,'#AAB3C0')
  remote(d,1013,656,u,2<u<7,.40)
  for j in range(32):
   amp=(18+16*math.sin(j*.8+u*8)) if 2<u<7 else 3
   xx=1160+j*15;d.line((xx,715-amp,xx,715+amp),fill=GREEN,width=6)
  text(d,(1160,760),'按住语音键说话' if u<7 else '松开，文字瞬间整齐上屏！',28,BLUE)
 else:
  rr(d,(978,310,1780,807),'white',35,LINE)
  center(d,1380,350,'Vibe Coding 时代的语音输入神器',38,BLUE)
  center(d,1380,425,'Remote Buddy · 遥控搭子',46)
  center(d,1380,515,'100% 本地运行 · 零音频留存 · GPL-3.0 开源',26,GREEN)
  center(d,1380,590,'remote.zfdang.com',46,BLUE)
  center(d,1380,685,'前往官网下载，即刻体验！',30)

 rr(d,(76,886,1844,1036),'#253449',24)
 lines=wrap(d,scenes[i][3],32,1700)
 chunks=subtitle_chunks(scenes[i][3])
 spoken=voice_lengths[i] if voice_lengths else 14.0
 position=min(1,u/spoken)*sum(len(c) for c in chunks)
 offset=0; chunk=chunks[-1]
 for c in chunks:
  offset+=len(c)
  if position < offset: chunk=c; break
 for k,l in enumerate(wrap(d,chunk,36,1670)):center(d,W/2,920+k*44,l,36,'white')
 text(d,(96,849),'产品宣传与操作演示  ·  macOS',24,'#8793A5')
 text(d,(1630,849),f'{i+1:02d} / {len(scenes):02d}',24,'#8793A5')
 rr(d,(76,1069,1844,1077),'#DFE7F2',4)
 rr(d,(76,1069,76+1768*total/total_duration,1077),BLUE,4)
 fade=min(1,u/.3,(12-u)/.3)
 if fade<1:im=Image.blend(Image.new('RGB',(W,H),BG),im,fade)
 return im

def subtitle_chunks(narration):
 pieces=re.findall(r'[^。！？]+[。！？]?',narration)
 chunks=[]
 for p in pieces:
  if len(p)<=42:chunks.append(p)
  else:
   parts=re.findall(r'[^，]+，?',p); current=''
   for part in parts:
    if len(current+part)>42 and current:chunks.append(current);current=''
    current+=part
   if current:chunks.append(current)
 return chunks

def stamp(seconds):
 ms=int(seconds*1000);return f'{ms//3600000:02}:{ms//60000%60:02}:{ms//1000%60:02},{ms%1000:03}'
