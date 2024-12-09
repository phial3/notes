# Loader 引导程序

[toc]



## Loader 原理



Loader引导加载程序负责**检测硬件信息**、**处理器模式切换**、**向内核传递数据**三部分工作，这些工作为内核的初始化提供信息及功能支持，以便内核在完成初始化工作后能够正常运行。下面将对这三部分内容逐一讲解。



### 检测硬件信息

Loader引导加载程序需要检测的硬件信息很多，主要是**通过BIOS中断**服务程序来获取和检测硬件信息。

由于BIOS在上电自检出的大部分信息只能在实模式下获取，而且内核运行于非实模式下，那么就必须<u>在进入内核程序前将这些信息检测出来，再作为参数提供给内核程序使用</u>。



在这些硬件信息中，最重要的莫过于**物理地址空间信息**，只有正确解析出物理地址空间信息，才能知道ROM、RAM、设备寄存器空间和内存空洞等资源的物理地址范围，进而将其交给内存管理单元模块加以维护。还有VBE功能，通过VBE功能可以检测出显示器支持的分辨率、显示模式、刷新率以及显存物理地址等信息，有了这些信息才能配置出合理的显示模式。



### 处理器模式切换

从起初**BIOS运行的实模式**（real mode），到**32位操作系统使用的保护模式**（protect mode），再到64位操作系统使用的IA-32e模式（long mode，长模式）, Loader引导加载程序必须历经这三个模式，才能使处理器运行于64位的IA-32e模式。

在各个模式的切换过程中，Loader引导加载程序必须手动创建各运行模式的临时数据，并按照标准流程执行模式间的跳转。其中有配置系统临时页表的工作，即既要根据各个阶段的页表特性设置临时页表项，还要保证页表覆盖的地址空间满足程序使用要求。临时段结构亦是如此。



### 向内核传递数据

Loader引导加载程序可向内核程序传递两类数据，<u>一类是控制信息，另一类是硬件数据信息</u>。这些数据一方面控制内核程序的执行流程，另一方面为内核程序的初始化提供数据信息支持。

-  **控制信息**一般<u>用于控制内核执行流程或限制内核的某些功能</u>。这些数据（参数）是与内核程序早已商定的协议，属于纯软件控制逻辑，如启动模式（字符界面或图形界面）、启动方式（网络或本地）、终端重定向（串口或显示器等）等信息。
- **硬件数据信息**通常<u>是指Loader引导加载程序检测出的硬件数据信息</u>。Loader引导加载程序将这些数据信息多半都保存在固定的内存地址中，并将数据起始内存地址和数据长度作为参数传递给内核，以供内核程序在初始化时分析、配置和使用，典型的数据信息有内存信息、VBE信息等。





## Loader 流程



### 1. 开启大于 1MB 寻址



在 boot.asm 启动程序中，设置了：

```assembly
BaseOfLoader        equ         0x1000
OffsetOfLoader      equ         0x00
```



也就是最终将 loader.bin 文件起始地址<u>加载到物理地址0x100000（1 MB）处</u>，因为1 MB 以下的物理地址并不全是可用内存地址空间，这段物理地址被划分成若干个子空间段，它们可以是内存空间、非内存空间以及地址空洞。随着内核体积的不断增长，未来的内核程序很可能会超过 1 MB，因此**让内核程序跳过这些纷繁复杂的内存空间，从平坦的1 MB 地址开始，这是一个非常不错的选择**。



那么问题来了，由于内核程序的读取操作是**通过 BIOS 中断服务程序INT 13h实现的，BIOS 在实模式下只支持上限为 1 MB 的物理地址空间寻址**。如何将内核程序加载到 1MB 开始处呢？

这里使用了临时转存空间，内存地址0x7E00是内核程序的临时转存空间，先将<u>内核程序读入到临时转存空间，然后再通过特殊方式（保护模式）搬运到1MB以上的内存空间中</u>。当内核程序被转存到最终内存空间后，这个临时转存空间就可另作他用，此处将其改为内存结构数据的存储空间，供内核程序在初始化时使用。



在 Fat12 文件系统中寻找并加载 kernel.bin 文件第四章 boot.asm 中已经介绍，不再赘述。

这里着重说明一下将内核程序拷贝到 1MB 开始处的内容。



通常情况下，实模式只能寻址1 MB以内的地址空间。为了突破这一瓶颈，接下来的代码将开启1 MB以上物理地址寻址功能，同时还开启了实模式下的4 GB寻址功能。

开启地址A20功能，此项功能属于历史遗留问题。最初的处理器只有20根地址线，这使得处理器只能寻址 1MB 以内的物理地址空间，如果超过 1 MB 范围的寻址操作，也只有低 20 位是有效地址。

随着处理器寻址能力的不断增强，20根地址线已经无法满足今后的开发需求。为了保证硬件平台的向下兼容性，便出现了一个控制开启或禁止 1 MB 以上地址空间的开关。当时的 8042 键盘控制器上恰好有空闲的端口引脚（输出端口 P2，引脚 P21），从而使用此引脚作为功能控制开关，即 A20 功能。如果 A20 引脚为低电平（数值0），那么只有低20位地址有效，其他位均为0。

在机器上电时，默认情况下A20地址线是被禁用的，所以操作系统必须采用适当的方法开启它。由于硬件平台的兼容设备种类繁杂，进而出现多种开启A20功能的方法：

- 开启A20功能的常用方法是操作键盘控制器，由于键盘控制器是低速设备，以至于功能开启速度相对较慢。
- A20快速门（Fast Gate A20），它使用I/O端口 0x92 来处理 A20 信号线。对于不含键盘控制器的操作系统，就只能使用 0x92 端口来控制，但是该端口有可能被其他设备使用。
- 使用 BIOS 中断服务程序 INT 15h 的主功能号 AX=2401 可开启 A20 地址线，功能号 AX=2400 可禁用 A20 地址线，功能号 AX=2403 可查询 A20 地址线的当前状态。
- 还有一种方法是，通过读 0xee 端口来开启 A20 信号线，而写该端口则会禁止 A20 信号线。

详细介绍在 `ch03-保护模式/1.保护模式入门.md` 中。

```assembly
		; ============================================
; GDT 描述符声明代码段
[SECTION    .gdt]
LABEL_GDT:              dd              0, 0                        ; 空描述符
LABEL_DESC_CODE32:      dd              0x0000FFFF,0x00CF9A00       ; 32位代码段描述符
LABEL_DESC_DATA32:      dd              0x0000FFFF,0x00CF9200       ; 32位数据段描述符


GdtLen              equ             $ - LABEL_GDT                   ; GDT 长度
GdtPtr              dw              GdtLen - 1                      ; GDT 界限
                    dd              LABEL_GDT                       ; GDT 基地址

; ------------------

; 段选择子
SelectorCode32      equ             LABEL_DESC_CODE32 - LABEL_GDT
SelectorData32      equ             LABEL_DESC_DATA32 - LABEL_GDT

; ============================================
		
		; 打开地址线 A20
		push            ax
		in			    al,		        92h
		or			    al,		        00000010b
		out			    92h,	        al
        pop             ax

        cli                                                 ; 关闭外部中断
        lgdt            [GdtPtr]                            ; 加载 GDTR，全局描述符基地址加载到 GDTR 寄存器

        ; 切换到保护模式
        mov			    eax,	        cr0
        or			    eax,	        1
        mov			    cr0,	        eax

        mov             ax,             SelectorData32
        mov             fs,             ax                  ; 将 SelectorData32 段选择子赋值给 fs
        ; 注意，这里的 SelectorData32 是保护模式下的段选择子，可以32位寻址的

        ; 关闭保护模式
        mov             eax,            cr0
        and             al,             11111110b
        mov             cr0,            eax

        sti                                                 ; 开启外部中断
```

说明：

- 设置在保护模式下的全局描述符 GDT，以及段选择子，以便后续初始化及使用
- 打开 A20 地址线
- 关闭中断
- 加载 GDT 全局描述符的基地址到 GDTR 寄存器，为切换到保护模式作准备
- 切换到保护模式
- 在保护模式下，将 SelectorData32 赋值给 fs 段寄存器，为了让 fs 段寄存器可以在实模式下寻址能力超过1 MB
- 关闭保护模式

注意：

- GDT 描述符一共有 8 字节，一共 64 位，以 LABEL_DESC_DATA32 为例，
- GDT 描述符的第 0,1 字节表示 段界限1，0xFFFF，（注意 0x0000FFFF 低位在后，即 0xFFFF）
- GDT 描述符的第 2,3,4 字节表示 段基址1，0x000000, (注意 0x0000 为 2,3 字节，0x00CF9200 的低位 0x00 表示 第 4 字节，即 0x000000
- GDT 描述符的第 5,6 字节表示属性，
  - 其中第 5 字节为 0x92(1001 0010)
    - 第 4 位表示 S 标志为 1，代表数据/代码段描述符
    - 第 0-3 位表示 Type 标志，0010 表示 读/写
    - 第 5-6 位表示 DPL 标志为，00 表示特权级 0
    - 第 7 位表示 P 标志为 1，表示段在内存中
    - 其中第 6 字节为 0xCF(1100 1111)
    - 第 0-3 位表示 段界限2，1111
    - 第 4 位表示 AVL 标志，保留位为0
    - 第 5 位为 0
    - 第 6 位表示 D/B 标志，为 1, 段界限粒度为 4KB
    - 第 7 位表示 G 标志，段的上部界限为 4GB
  - GDT 描述符的第 7 字节表示 段基址2，0x00，(注意 0x00CF9A00 的高位就是 第 7 字节，即 0x00)
- LABEL_DESC_CODE32 不同的地方就是 属性标志，0x9A(1001 1010)，第 0-3 位表示 Type 标志，1010 表示 执行 / 读



在实模式下我们需要准备保护模式运行所必须的 GDT 以及代码段描述符和数据段描述符，接着开启 A20 地址线并跳转至保护模式，这一切都按照实模式切换至保护模式的流程执行即可。

当进入保护模式后，直接向目标段寄存器载入段选择子，处理器在向目标段寄存器加载段选择子的同时，还将段描述符加载到目标段寄存器中（隐藏部分），随后再切换回实模式。<u>如果此后目标段寄存器值不再修改，那么目标段寄存器仍然缓存着段描述符信息</u>。

现在，**如果使用目标段寄存器访问内存的话，处理器依然会采用保护模式的逻辑地址寻址方式，即使用目标段基地址加32位段内偏移的方式**。请注意，如果在实模式下重新对目标段寄存器进行赋值，处理器会覆盖段寄存器缓存的段描述符信息，从而导致目标段寄存器无法再进行4 GB寻址，除非再次进入保护模式为目标段寄存器加载段选择子。





### 2. 拷贝临时区到 1MB 内存地址处

```assembly
        add             cx,             DeltaSectorNo            ; 这部分主要是计算起始簇号 FAT[n] 的位置（原理见前）
        ; 此时，cx 是起始簇号对应在 FAT 中的位置

        mov             ax,             BaseTmpOfKernelFile
        mov             es,             ax
        mov             bx,             OffsetTmpOfKernelFile     ; 先将 kernel 内核程序加载到临时缓冲区
        mov             ax,             cx
        ; 此时 es:bx 表示将 kernel.bin 文件内容加载到内存的位置
        ; ax 是 kernel.bin 文件起始簇的逻辑扇区号(扇区号)


Label_Go_On_Loading_File:         ; 加载 kernel.bin 文件内容
; 通过 Bios 中断 INT 10H 显示服务， 功能 0EH 在 Teletype 模式下显示字符

		.........
		
        ; 开始加载 kernel.bin 文件内容
        mov             cl,             1                       ; 读取 1 个扇区
        call            Func_ReadOneSector                      ; 从 kernel.bin 文件的起始扇区号 ax 开始加载，加载到 es:bx, 也就是读取当前簇号对应的数据区的扇区内容到内存

        pop             ax                                      ; 上面还有 cx 没有出栈，ax = cx，根目录项中的起始簇号

        ; -------------------------- 此时已经读取了一个扇区到缓冲区，移动至1 MB以上的物理内存空间
        push	        cx
        push	        eax
        push	        fs
        push	        edi
        push	        ds
        push	        esi

        mov             cx,             200h                    ; cx 控制循环次数，200h=512，每次读取1字节，读完一个扇区，512 次
        mov             ax,             BaseOfKernelFile        ; 最终内核文件的内存位置，大于 1MB
        mov             fs,             ax
        mov             edi,            dword       [OffsetOfKernelFileCount]       ;   fs:edi 表示的是内核真实的地址

        mov             ax,             BaseTmpOfKernelFile
        mov             ds,             ax
        mov             esi,            OffsetTmpOfKernelFile                       ; ds:esi 表示的是内核缓冲区的地址

Label_Mov_To_Kernel:                ; 拷贝
        mov             al,             byte        [ds:esi]
        mov             byte        [fs:edi],       al
        ; 将 ds:esi 临时缓冲区的一个字节 拷贝 fs:edi 指向的 kernel 地址（大于1MB）

        inc             esi
        inc             edi

        loop            Label_Mov_To_Kernel

        mov             eax,            0x1000
        mov             ds,             eax                                         ; 恢复 ds
        mov             dword       [OffsetOfKernelFileCount],      edi             ; 内核真实地址的偏移增加

        pop	            esi
        pop	            ds
        pop	            edi
        pop	            fs
        pop	            eax
        pop	            cx


        ; --------------------------

        call            Func_GetFATEntry                    ; ah 保存起始簇号，调用 Func_GetFATEntry 获取到 FAT[ah] 对应的值，包括了下一个簇号
        ; Func_GetFATEntry 函数调用后，AX 的低 12 位保存了 FAT[原ah] 的值
```



说明：

- 其实就是将缓冲区扇区中的内容，一字节一字节的拷贝到目标内核内存地址处 BaseOfKernelFile
- 其中维护了一个目标内存地址的偏移量，OffsetOfKernelFileCount，每次会接着此偏移量继续往后拷贝
- 注意，这里的 fs 的界限已经超过了 1MB ，可达到 4GB 内存寻址





### 3. 关闭软驱马达



```assembly
;----------------------------------------------------------------------------
; 函数名: KillMotor
;----------------------------------------------------------------------------
; 作用:
;	关闭软驱马达
KillMotor:
	    push	        dx
	    mov	            dx,             03F2h                   ; 关闭软驱马达是通过向I/O端口3F2h写入控制命令实现的
	    mov	            al,             0
	    out	            dx,             al
	    pop	            dx
	    ret
;----------------------------------------------------------------------------
```



既然已将内核程序从软盘加载到内存，便可放心地向此I/O端口写入数值0关闭全部软盘驱动器。在使用OUT汇编指令操作I/O端口时，需要特别注意8位端口与16位端口的使用区别。



### 4. 获取内存结构信息

物理地址空间信息由一个结构体数组构成，计算机平台的地址空间划分情况都能从这个结构体数组中反映出来，它记录的地址空间类型包括可用物理内存地址空间、设备寄存器地址空间、内存空洞等。

这段程序借助BIOS中断服务程序INT 15h来获取物理地址空间信息，并将其保存在0x7E00（MemoryStructBufBase:MemoryStructBufOffset）地址处的临时转存空间里，操作系统会在初始化内存管理单元时解析该结构体数组。



详细如何获取内存结构信息见 `OrangeOS/ch03-保护模式/5.保护模式之分页.md`

代码如下：

```assembly
;----------------------------------------------------------------------------
; 函数名: GetMemStructInfo
;----------------------------------------------------------------------------
; 作用:
;	在实模式下，获取内存，调用 int 15h 子功能 ax=0E820h
GetMemStructInfo:
        ; 打印信息，开始检查内存
        mov             ax,                 StartGetMemStructMessage            ; 显示字符串
        mov             dx,                 0400h                               ; 游标位置，(DH、DL)＝游标坐标(行、列)，1行0列
        mov             cx,                 GetMemMessageLength                 ; 显示长度
        call            DisplayStrRealMode

		; 在实模式下，获取内存，调用 int 15h 子功能 ax=0E820h
		mov             ebx,                0                                   ; 输入 ebx，后续值(continuation value)，第一次为 0
		mov             ax,                 MemoryStructBufBase
		mov             es,                 ax
		mov             di,                 MemoryStructBufOffset               ; 输入 es:di，会将 ARDS（Address Range Descriptor Structure）填充到此处
		; 之前已经将 es 赋值，es:di 表示了缓冲区的地址

.loop:                      ; 循环执行 int 15h，获取内存
        mov             eax,                0E820h              ; 输入 eax，功能码
        mov             ecx,                20                  ; 输入 ecx，用于限制指令填充的 ARDS 的大小，通常为 20
        mov             edx,                0534D4150h          ; 输入 edx，BIOS 将会使用此标志，对调用者将要请求的系统映像信息进行校验，这些信息会被 BIOS 放置到 `es:di` 所指向的结构中

        int             15h                                     ; 执行 15h 中断

        jc              LABEL_MEM_CHK_FAIL                      ; 当没有发生错误时，CF=0，否则 CF=1
        ; 如果 cf = 0，发生错误，跳转到 LABEL_MEM_CHK_FAIL ，结束循环

        add             di,                 20                  ; 在每一次循环进行时，寄存器di的值将会递增，每次的增量为 20 字节，因为每次读取的信息是 20 字节
        inc             dword               [_MCRNumber]        ; _MCRNumber 是一个计数器，每次循环让 _MCRNumber 的值加 1
        ; 到循环结束时它的值会是循环的次数，同时也是地址范围描述符结构ARDS的个数。

        cmp             ebx,                0                   ; 指向下一个内存区域，而不是调用之前的内存区域，当 ebx=0 且 CF=0 时，表示当前是最后一个内存区域。
        jne             .loop                                   ; 如果不为0,表示还没读取完成
        jmp             LABEL_MEM_CHK_OK                        ; 否则读取完成


LABEL_MEM_CHK_FAIL:                 ; 如果读取失败
        ; 打印信息，检查内存失败
        mov             ax,                 GetMemStructErrMessage              ; 显示字符串
        mov             dx,                 0500h                               ; 游标位置，(DH、DL)＝游标坐标(行、列)，1行0列
        mov             cx,                 GetMemErrMessageLength              ; 显示长度
        call            DisplayStrRealMode
        mov             dword               [_MCRNumber],      0                ; 将读取次数 MCRNumber 复位
        jmp             $


LABEL_MEM_CHK_OK:                   ; 如果读取成功，继续执行实模式后续代码
        ; 打印信息，检查内存成功
        mov             ax,                 GetMemStructOKMessage            ; 显示字符串
        mov             dx,                 0500h                            ; 游标位置，(DH、DL)＝游标坐标(行、列)，1行0列
        mov             cx,                 GetMemOKMessageLength            ; 显示长度
        call            DisplayStrRealMode
	    ret
;----------------------------------------------------------------------------
```





### 5. 获取 VBE 相关信息

```assembly
;----------------------------------------------------------------------------
; 函数名: GetSVGAModeInfo
;----------------------------------------------------------------------------
; 作用:
;	在实模式下，获取内存，调用 int 15h 子功能 ax=0E820h
GetSVGAModeInfo:
        ; 打印信息，开始获取 svga 信息
        mov             ax,                 StartGetSVGAVBEInfoMessage             ; 显示字符串
        mov             dx,                 0600h                                   ; 游标位置，(DH、DL)＝游标坐标(行、列)，1行0列
        mov             cx,                 StartGetSVGAVBEInfoMessageLength            ; 显示长度
        call            DisplayStrRealMode

        ; ====== step 1. 获取VBE控制器信息
        mov             ax,                 TmpBaseOfBuff
        mov             es,                 ax
        mov             di,                 TmpOffsetOfBuff
        mov             ax,                 4F00h                                   ; VBE 规范的 00h 号功能可为调用者提供已安装的VBE软件和硬件信息
        int             10h
        ; 保存的结果在 es:di 中，也就是临时缓存区保存着 VbeInfoBlock 信息块结构

        cmp             ax,                 004Fh                                   ; AL=4Fh 支持该功能，AH=00h 操作成功
        jz              .KO                                                         ; 操作成功，跳转，操作失败，打印失败信息

        ; 操作失败，打印失败信息
        mov             ax,                 GetSVGAVBEInfoErrMessage                ; 显示字符串
        mov             dx,                 0700h                                   ; 游标位置，(DH、DL)＝游标坐标(行、列)，1行0列
        mov             cx,                 GetSVGAVBEInfoErrMessageLength          ; 显示长度
        call            DisplayStrRealMode
        jmp             $                                                           ; 失败以后，停止运行

.KO:        ; 获取 VBE 控制信息 操作成功
        ; 操作成功，打印成功信息
        mov             ax,                 GetSVGAVBEInfoOKMessage                ; 显示字符串
        mov             dx,                 0700h                                   ; 游标位置，(DH、DL)＝游标坐标(行、列)，1行0列
        mov             cx,                 GetSVGAVBEInfoOKMessageLength          ; 显示长度
        call            DisplayStrRealMode

        ; ====== step 2. 获取VBE模式信息
        ; 打印信息，开始获取 svga 模式信息
        mov             ax,                 StartGetSVGAModeInfoMessage             ; 显示字符串
        mov             dx,                 0800h                                   ; 游标位置，(DH、DL)＝游标坐标(行、列)，1行0列
        mov             cx,                 GetSVGAModeInfoMessageLength            ; 显示长度
        call            DisplayStrRealMode


        ; 此时的 TmpBaseOfBuff:TmpOffsetOfBuff 指向 VbeInfoBlock 信息块结构的起始地址
        mov             ax,                 TmpBaseOfBuff
        mov             es,                 ax
        mov             si,                 TmpOffsetOfBuff + 14                    ; VbeInfoBlock 信息块结构的第14字节开始的4B，表示 VideoModePtr 指针

        mov             esi,                dword       [es:si]                     ; es:si 指向的双字（4B），给 esi
        mov             edi,                TmpOffsetOfBuff + 512                   ; edi 指向显示模式扩展信息

        ; esi 保存 VbeInfoBlock.VideoModePtr
        ;   - VideoModePtr是个执行模式号列表（VBE芯片能够支持的模式号）的远指针，一般指向VbeInfoBlock.Reserved
        ; edi指向VbeInfoBlock.OemData
        ;   - 但是我们不关心VbeInfoBlock.OemData中的数据，从0x8200之后的内存空间用于保存VBE显示模式扩展信息（ModeInfoBlock）

Label_SVGA_Mode_Info_Get:               ; 获取所有的模式信息，[es:esi] 指向模式列表 VideoModeList
        mov             cx,                 word        [es:esi]                    ; VideoModeList 每个模式号有 16位，2个字节，

        ;======= Step3.	显示每个模式信息
        push            ax

        mov             ax,                 00h
        mov             al,                 ch
        call            Display_AL                                                  ; 显示高8位

        mov             ax,                 00h
        mov             al,                 cl
        call            Display_AL                                                  ; 显示高8位

        mov             ax,                 ','                                     ; 分隔符
	    mov	            [gs:DisplayPosition],	        ax
	    mov             ax,                 [DisplayPosition]
	    add	            ax,	                2
	    mov             [DisplayPosition],              ax

        pop             ax

        cmp             cx,                 0FFFFh
        jz              Label_SVGA_Mode_Info_Finish                                 ; 判断是否读取完成

        ;======= Step4. 获取 VBE 每个模式的具体信息
        mov             ax,                 4F01h
        int             10h                                                         ; BE 规范的 01h 号功能用于获得指定模式号（自于VideoModeList列表）的 VBE 显示模式扩展信息

        cmp             ax,                 004Fh                                   ; 判断返回状态，支持且操作成功
        jnz             Label_SVGA_Mode_Info_FAIL                                   ; 操作失败，跳转

        add             esi,                2
        add             edi,                0100h

        jmp             Label_SVGA_Mode_Info_Get

Label_SVGA_Mode_Info_FAIL:
        ; 打印信息，svga 模式信息获取失败
        mov             ax,                 GetSVGAModeInfoErrMessage               ; 显示字符串
        mov             dx,                 0900h                                   ; 游标位置，(DH、DL)＝游标坐标(行、列)，1行0列
        mov             cx,                 GetSVGAModeInfoErrMessageLength         ; 显示长度
        call            DisplayStrRealMode

Label_SET_SVGA_Mode_VESA_VBE_FAIL:
        mov             ax,                 GetSVGAModeInfoOKMessage                ; 显示字符串
        mov             dx,                 0900h                                   ; 游标位置，(DH、DL)＝游标坐标(行、列)，1行0列
        mov             cx,                 GetSVGAModeInfoOKMessageLength          ; 显示长度
        call            DisplayStrRealMode

        jmp             $

Label_SVGA_Mode_Info_Finish:
        ; 打印信息，svga 模式信息获取成功
        mov             ax,                 GetSVGAModeInfoOKMessage                ; 显示字符串
        mov             dx,                 0900h                                   ; 游标位置，(DH、DL)＝游标坐标(行、列)，1行0列
        mov             cx,                 GetSVGAModeInfoOKMessageLength          ; 显示长度
        call            DisplayStrRealMode

        ;======= Step5. 设置 VBE 显示模式
        mov             ax,                 4F02h
        mov             bx,                 4180h
        ; 4180h = 0100 0001 1000 0000
        ; bx为显示模式号，结构如下：
        ; 0bit-7bit：VBE模式号（180h）
        ; 9bit-10bit：保留，0
        ; 11bit：0=使用当前刷新率，1=使用CRTC刷新率（0）
        ; 【11bit为复位时，es:di无效】
        ; 12bit-13bit：保留，0
        ; 14bit：0=窗口帧缓存区模式，1=线性帧缓存区模式（1）
        ; 15bit：0=清空显示内存数据，1=保留显示内存数据（0）
        ; es:di：CRTCInfoBlock结构的起始地址

	    cmp	            ax,	                004Fh
	    jnz	            Label_SET_SVGA_Mode_VESA_VBE_FAIL

        ret
;----------------------------------------------------------------------------
```



VBE 相关功能见 `VBE功能.md`





### 6. 从实模式进入保护模式再到IA-32e模式











### 7. 完整代码

完整代码位于 `ch05_Boot-Loader/b/loader.asm`



## 实模式的内存布局

| 起始地址 | 结束地址 |    大小    |        用途        |
| :------: | :------: | :--------: | :----------------: |
|  0x000   |  0x3FF   |    1KB     |     中断向量表     |
|  0x400   |  0x4FF   |    256B    |    BIOS 数据区     |
|  0x500   |  0x7BFF  |  29.75KB   |      可用区域      |
|  0x7C00  |  0x7DFF  |    512B    |     MBR 加载区     |
|  0x7E00  | 0x9FBFF  |  607.6KB   |      可用区域      |
| 0x9FC00  | 0x9FFFF  |    1KB     |  扩展 BIOS 数据区  |
| 0xA0000  | 0xAFFFF  |    64KB    | 用于彩色显示适配器 |
| 0xB0000  | 0xB7FFF  |    32KB    | 用于黑白显示适配器 |
| 0xB8000  | 0xBFFFF  |    32KB    | 用于文本显示适配器 |
| 0xC0000  | 0xC7FFF  |    32KB    |  显示适配器 BIOS   |
| 0xC8000  | 0xEFFFF  |   160KB    |      映射内存      |
| 0xF0000  | 0xFFFEF  | 64kB - 16B |     系统 BIOS      |
| 0xFFFF0  | 0xFFFFF  |    16B     | 系统 BIOS 入口地址 |

