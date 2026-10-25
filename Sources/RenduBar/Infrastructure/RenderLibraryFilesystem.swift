import Foundation
import CryptoKit
import Darwin

enum RenderLibraryFilesystem {
    enum Failure:Error {case invalid,changed,collision,io(Int32)}
    static func hash(_ file:URL,lifetime:RenderTaskLifetime?)throws->String {
        let fd=open(file.path,O_RDONLY|O_NOFOLLOW);guard fd>=0 else{throw Failure.invalid};defer{close(fd)}
        var st=stat();guard fstat(fd,&st)==0,(st.st_mode&S_IFMT)==S_IFREG else{throw Failure.invalid}
        var digest=SHA256(),buffer=[UInt8](repeating:0,count:1024*1024)
        while true {try Task.checkCancellation();try lifetime?.check();let n=read(fd,&buffer,buffer.count);guard n>=0 else{throw Failure.io(errno)};if n==0{break};digest.update(data:Data(buffer.prefix(n)))}
        return digest.finalize().map{String(format:"%02x",$0)}.joined()
    }
    static func syncDirectory(_ folder:URL)throws {
        let fd=open(folder.path,O_RDONLY|O_DIRECTORY|O_NOFOLLOW);guard fd>=0 else{throw Failure.invalid};defer{close(fd)}
        guard fsync(fd)==0 else{throw Failure.io(errno)}
    }
    static func copy(_ source:URL,_ target:URL,expected:RenderLibraryFileStamp,lifetime:RenderTaskLifetime?)throws->String {
        try RenderLibraryStore.directories(source.deletingLastPathComponent(),create:false)
        guard try RenderLibraryFileStamp.read(source)==expected else{throw Failure.changed}
        let input=open(source.path,O_RDONLY|O_NOFOLLOW);guard input>=0 else{throw Failure.invalid};defer{close(input)}
        var opened=stat();guard fstat(input,&opened)==0,UInt64(opened.st_dev)==expected.device,UInt64(opened.st_ino)==expected.inode,Int64(opened.st_size)==expected.bytes,Int64(opened.st_mtimespec.tv_sec)==expected.modifiedSeconds,Int64(opened.st_mtimespec.tv_nsec)==expected.modifiedNanoseconds else{throw Failure.changed}
        let output=open(target.path,O_WRONLY|O_CREAT|O_EXCL|O_NOFOLLOW,0o600);guard output>=0 else{throw errno==EEXIST ? Failure.collision:Failure.io(errno)};defer{close(output)}
        var digest=SHA256(),buffer=[UInt8](repeating:0,count:1024*1024)
        while true {
            try Task.checkCancellation();try lifetime?.check()
            let n=read(input,&buffer,buffer.count);guard n>=0 else{throw Failure.io(errno)};if n==0{break}
            digest.update(data:Data(buffer.prefix(n)))
            try buffer.withUnsafeBytes {b in var offset=0;while offset<n {let k=write(output,b.baseAddress!.advanced(by:offset),n-offset);guard k>0 else{throw Failure.io(errno)};offset+=k}}
        }
        guard fsync(output)==0,try RenderLibraryFileStamp.read(source)==expected else{throw Failure.changed}
        try syncDirectory(target.deletingLastPathComponent())
        return digest.finalize().map{String(format:"%02x",$0)}.joined()
    }
    static func exists(_ file:URL)->Bool {var s=stat();return lstat(file.path,&s)==0}
    static func removeOwned(_ file:URL,stamp:RenderLibraryFileStamp)throws {
        guard try RenderLibraryFileStamp.read(file)==stamp else{throw Failure.changed}
        guard unlink(file.path)==0 else{throw Failure.io(errno)};try syncDirectory(file.deletingLastPathComponent())
    }
    static func renameExclusive(_ a:URL,_ b:URL)throws {
        guard renamex_np(a.path,b.path,UInt32(RENAME_EXCL))==0 else{throw errno==EEXIST ? Failure.collision:Failure.io(errno)}
        try syncDirectory(a.deletingLastPathComponent());if a.deletingLastPathComponent() != b.deletingLastPathComponent(){try syncDirectory(b.deletingLastPathComponent())}
    }
}
