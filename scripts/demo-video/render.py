from pathlib import Path
import asyncio, json, subprocess, importlib.util, bisect
import edge_tts
import hashlib

ROOT=Path(__file__).resolve().parents[2]
BASE=ROOT/'dist/videos/source';BASE.mkdir(parents=True,exist_ok=True)
OUT=ROOT/'pages/assets/video'

spec=importlib.util.spec_from_file_location('visual',Path(__file__).with_name('visuals.py'));v=importlib.util.module_from_spec(spec);spec.loader.exec_module(v)

narrations=[
'在 Vibe Coding 时代，限制开发效率的早已不是大模型的能力，而是人类打字的物理瓶颈。动口说话比敲击键盘快三倍以上，语音输入正在成为与 AI 结对编程的最佳方式。',
'市面上的专用 AI 硬件动辄几百上千元，往往还捆绑订阅。其实，家里几十块钱的小米或 Google 电视蓝牙遥控器，天生自带微动麦克风按键和数月续航，是绝佳的掌上语音控制器。',
'Remote Buddy 是一款专为 macOS 设计的开源桥接工具。它能把电视遥控器直接变成 Mac 上的语音输入按钮。拿起遥控器，按住说话，松手结束，文字瞬间落在光标处。',
'它的设计极其克制与纯粹：应用本身不运行大模型，而是将遥控器的压缩音频实时解码送入免驱虚拟麦克风，并自动注入快捷键，识别与纠错全交给最成熟的输入工具。',
'前往官网下载安装包，一次性安装应用本体和虚拟麦克风驱动。驱动打上了系统级 USB 硬件伪装，系统和任何应用都能将其当作真实物理麦克风直接使用。',
'跟随设置向导开启蓝牙、输入监控与辅助功能权限。软件坚守纯本地运行原则：所有音频纯内存流转，绝不落盘、不存录音、无任何网络上传，遇到密码框还会自动安全降级。',
'目前已全面适配国内六七十元的小米蓝牙语音遥控器 2 和 2 Pro，以及海外广泛普及的 Google Chromecast G9N9N 遥控器。配对连接后，还支持独立的麦克风增益调节。',
'在输入法集成中，可自由搭配你最喜爱的工具：微信输入法、豆包、网易叭哥说、Typeless，乃至系统原生听写或本地离线 Whisper。无需绑定特定模型，你习惯哪款就用哪款。',
'遥控器所有按键均支持自定义映射！方向键与确认键可映射为 Tab 采纳代码补全或撤销。强大的常用语功能更允许你把常用 Prompt 和代码模板绑定按键，一键直出上屏。',
'无论是在 Cursor、VSCode 还是终端中，点击输入框，按住语音键说：把这段逻辑重构为异步并发，并增加测试。松开按键，文字瞬间整齐落定，让思维与编程同频。',
'Remote Buddy 基于 GPL-3.0 协议完全开源。前往 voice.zfdang.com 下载安装包。翻出抽屉里闲置的遥控器，用最便宜的硬件，开启极致顺滑的语音编程之旅吧！'
]

num_scenes = len(narrations)
for i,t in enumerate(narrations):v.scenes[i]=(*v.scenes[i][:3],t)

voice_paths=[BASE/f'yt11-{hashlib.sha256(t.encode()).hexdigest()[:16]}.mp3' for t in narrations]

async def voices():
 for i,t in enumerate(narrations):
  path=voice_paths[i]
  if not path.exists():
   for attempt in range(3):
    try:
     await edge_tts.Communicate(t,'zh-CN-XiaoxiaoNeural',rate='+0%').save(str(path));break
    except Exception:
     if attempt==2:raise
   print(f'Generated natural voice {i+1}/{num_scenes}',flush=True)

asyncio.run(voices())

durations=[float(subprocess.check_output(['ffprobe','-v','error','-show_entries','format=duration','-of','csv=p=0',str(voice_paths[i])])) for i in range(num_scenes)]
print(f'Speech seconds: {sum(durations):.2f}', durations, flush=True)

GAP = 1.8
lengths=[d + GAP for d in durations]
total_seconds = sum(lengths)
v.total_duration = total_seconds
boundaries=[0]
for d in lengths: boundaries.append(boundaries[-1]+d)
v.voice_lengths=[durations[i]*12/lengths[i] for i in range(num_scenes)]

srt=[]; n=1
for i in range(num_scenes):
 parts=v.subtitle_chunks(narrations[i]);offset=0;total=sum(map(len,parts))
 for p in parts:
  start=boundaries[i]+durations[i]*offset/total;offset+=len(p);end=boundaries[i]+durations[i]*offset/total
  srt.append(f'{n}\n{v.stamp(start)} --> {v.stamp(end)}\n{p}\n');n+=1
 subprocess.run(['ffmpeg','-v','error','-y','-i',str(voice_paths[i]),'-af','apad','-t',str(lengths[i]),'-ar','48000','-ac','1',str(BASE/f'yt-scene-{i}.wav')],check=True)

(OUT/'demo.zh-CN.vtt').write_text('WEBVTT\n\n'+'\n'.join(srt).replace(',', '.'))
(BASE/'script-natural.zh-CN.json').write_text(json.dumps({'voice':'zh-CN-XiaoxiaoNeural','scenes':v.scenes,'durations':lengths},ensure_ascii=False,indent=2))
(BASE/'yt-concat.txt').write_text(''.join(f"file '{BASE/f'yt-scene-{i}.wav'}'\n" for i in range(num_scenes)))

subprocess.run(['ffmpeg','-v','error','-y','-f','concat','-safe','0','-i',str(BASE/'yt-concat.txt'),'-c:a','pcm_s16le',str(BASE/'yt-narration.wav')],check=True)

video=OUT/'Remote_Buddy_Demo_Natural_zh-CN.mp4'
total_duration_str = f'{total_seconds:.2f}'

cmd=['ffmpeg','-v','error','-y','-f','rawvideo','-pix_fmt','rgb24','-s','1920x1080','-r','12','-i','-','-i',str(BASE/'yt-narration.wav'),'-r','24','-c:v','libx264','-preset','fast','-crf','20','-pix_fmt','yuv420p','-c:a','aac','-b:a','160k','-af','loudnorm=I=-16:TP=-1.5:LRA=11','-t',total_duration_str,'-movflags','+faststart',str(video)]

proc=subprocess.Popen(cmd,stdin=subprocess.PIPE);previous=-1
total_frames = int(total_seconds * 12)

print(f'Starting render of {num_scenes} scenes, total {total_seconds:.2f}s ({total_frames} frames)...', flush=True)

for f in range(total_frames):
 t=f/12;i=min(num_scenes-1,bisect.bisect_right(boundaries,t)-1);u=(t-boundaries[i])*12/lengths[i]
 proc.stdin.write(v.frame(i,u,t).tobytes())
 if previous!=i:
  print(f'Rendered natural scene {i+1}/{num_scenes}',flush=True)
  previous=i

proc.stdin.close()
assert proc.wait()==0
print(f'Video rendered successfully: {video}', flush=True)

subprocess.run(['ffmpeg','-v','error','-y','-ss','6','-i',str(video),'-frames:v','1',str(OUT/'demo-poster.jpg')],check=True)
print('Poster updated successfully', flush=True)
