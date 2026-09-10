#!/usr/bin/env python3
"""Inspect Mach-O methods in a linked binary; does not execute iOS code."""
import struct, uuid
class MachO:
    def __init__(self, data):
        self.data=data
        assert self.u32(0)==0xfeedfacf, 'Expected little-endian 64-bit Mach-O'
        self.sections=[]; self.segments=[]; self.symbols={}; self.uuid=None
        self.commands=[]; self.rebases={}; at=32; symtab=None; fixups=None
        for _ in range(self.u32(16)):
            cmd,size=struct.unpack_from('<II',data,at); self.commands.append(cmd)
            assert size>=8 and at+size<=len(data)
            if cmd==0x19:
                name=data[at+8:at+24].split(b'\0')[0].decode()
                vm,vms,off,filesz=struct.unpack_from('<4Q',data,at+24)
                self.segments.append((name,vm,vms,off,filesz))
                for i in range(self.u32(at+64)):
                    a=at+72+i*80
                    sn=data[a:a+16].split(b'\0')[0].decode()
                    addr,ss,so=struct.unpack_from('<QQI',data,a+32)
                    self.sections.append((name,sn,addr,ss,so))
            if cmd==2: symtab=struct.unpack_from('<4I',data,at+8)
            if cmd==0x80000034: fixups=self.u32(at+8)
            if cmd==0x1b: self.uuid=str(uuid.UUID(bytes=data[at+8:at+24]))
            at+=size
        if fixups is not None:self.load_fixups(fixups)
        if symtab:
            sy,n,st,sz=symtab
            for i in range(n):
                ix,ty,sec,desc,val=struct.unpack_from('<IBBHQ',data,sy+i*16)
                if ix and (ty&0x0e)==0x0e:
                    self.symbols[self.cstring(st+ix)]=(val,sec)
    def load_fixups(self, base):
        starts=base+self.u32(base+4)
        imagebase=next(vm for name,vm,_,off,sz in self.segments if name=='__TEXT')
        for i in range(self.u32(starts)):
            rel=self.u32(starts+4+i*4)
            if not rel:continue
            st=starts+rel
            page,fmt=struct.unpack_from('<HH',self.data,st+4)
            segoff=self.u64(st+8); count=struct.unpack_from('<H',self.data,st+20)[0]
            assert fmt in (2,6), 'Unsupported chained pointer format '+str(fmt)
            for j in range(count):
                start=struct.unpack_from('<H',self.data,st+22+j*2)[0]
                if start==0xffff:continue
                assert not start&0x8000, 'Multi-start chains not yet supported'
                va=imagebase+segoff+j*page+start
                for guard in range(page//4+1):
                    off=self.offset(va);raw=self.u64(off);nxt=(raw>>51)&0xfff
                    if not (raw>>63):
                        target=raw&((1<<36)-1);high=(raw>>36)&0xff
                        target=(target | (high<<56)) if fmt==2 else (imagebase+target)|(high<<56)
                        self.rebases[off]=target
                    if not nxt:break
                    va+=nxt*4
                else:raise ValueError('Invalid fixup chain')
    def ptr(self, off):return self.rebases.get(off,self.u64(off))
    def u32(self, off): return struct.unpack_from('<I',self.data,off)[0]
    def u64(self, off): return struct.unpack_from('<Q',self.data,off)[0]
    def offset(self, va):
        for _,vm,_,off,sz in self.segments:
            if vm<=va<vm+sz:return off+va-vm
        raise ValueError('Unmapped address '+hex(va))
    def cstring(self, off):
        end=self.data.index(b'\0',off)
        return self.data[off:end].decode()
    def string_at(self, va):return self.cstring(self.offset(va))
    def section(self, name):return next(s for s in self.sections if s[1]==name)
    def methods(self, classname):
        _,_,addr,size,off=self.section('__objc_classlist')
        for i in range(size//8):
            cls=self.ptr(off+i*8); co=self.offset(cls)
            ro=self.ptr(co+32)&~7; r=self.offset(ro)
            name=self.string_at(self.ptr(r+24))
            if name!=classname:continue
            mva=self.ptr(r+32); m=self.offset(mva)
            flags,count=struct.unpack_from('<II',self.data,m)
            entrysize=flags&0xfffc; result={}
            for j in range(count):
                e=mva+8+j*entrysize; f=self.offset(e)
                if flags&0x80000000:
                    nr,_,ir=struct.unpack_from('<iii',self.data,f)
                    nv=e+nr
                    if not flags&0x40000000:nv=self.ptr(self.offset(nv))
                    imp=e+8+ir
                else:nv=self.ptr(f);imp=self.ptr(f+16)
                result[self.string_at(nv)]=hex(imp)
            return result
        raise ValueError('Class not found '+classname)
if __name__=='__main__':
    import sys,json,pathlib
    b=MachO(pathlib.Path(sys.argv[1]).read_bytes())
    print(json.dumps({'uuid':b.uuid,'methods':{k:v for k,v in b.methods('CameraViewController').items() if 'Photo' in k or 'ResolvedSettings' in k or 'Recording' in k}},indent=2))
