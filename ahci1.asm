
	.386
	.MODEL FLAT, stdcall
	option casemap:none
	option proc:private

lf	equ 10

CStr macro text:vararg
local sym
	.const
sym db text,0
	.code
	exitm <offset sym>
endm

@pe_file_flags = @pe_file_flags and not 1	;create binary with base relocations

	include dpmi.inc

;--- the command list consists of 32 commands a 32 bytes = 1024 bytes
;--- header of a command in the command List:
CHStruct struct
flags1 db ?	;P[7]=Prefetchable, W[6]=Write, A[5]=ATAPI, CFL[4:0]=Command FIS Length
flags2 db ? ;PMP[15:12]=Port Multiplier Port, R[11]=Reserved, C[10]=Clear Busy, B[9]=BIST, R[8]=Reset
PRDTL dw ?	;Physical Region Descriptor Table Length
PRDBC dd ?	;Physical Region Descriptor Byte Count
CTBA0 dd ?	;Command Table Base Address
CTBA_U0 dd ?;Command Table Base Address Upper
CHStruct ends

;--- Command Table
;--- 00-3F: Command FIS
;--- 40-5F: ATAPI Command
;--- 60-7F: Reserved
;--- 80-XXXX: PRDT: Physical Region Descriptor Table
;---   DBA - Data Base Address QWORD
;---   reserved DWORD
;---   I[31]: Interrupt of Completion, reserved[30:22], DBC[21:0]: Data Byte Count


	.data

rmstack dd ?
bVerbose db 0

	.CODE

	include printf.inc

int_1a proc
local rmcs:RMCS
	mov rmcs.rEDI,edi
	mov rmcs.rESI,esi
	mov rmcs.rEBX,ebx
	mov rmcs.rECX,ecx
	mov rmcs.rEDX,edx
	mov rmcs.rEAX,eax
	mov rmcs.rFlags,3202h
	mov rmcs.rES,0
	mov rmcs.rDS,0
	mov rmcs.rFS,0
	mov rmcs.rGS,0
	mov eax,rmstack
	mov rmcs.rSSSP,eax
	lea edi,rmcs
	mov bx,1Ah
	mov cx,0
	mov ax,0300h
	push ebp
	int 31h
	pop ebp
	jc @F
	mov ah,byte ptr rmcs.rFlags
	sahf
@@:
	mov edi,rmcs.rEDI
	mov esi,rmcs.rESI
	mov ebx,rmcs.rEBX
	mov ecx,rmcs.rECX
	mov edx,rmcs.rEDX
	mov eax,rmcs.rEAX
	ret
int_1a endp


displayfis proc uses ebx esi dwFIS:dword
	invoke printf, CStr("      (received) FIS at 0x%X, size=0x100 (DSFIS=+0 PSFIS=+0x20 RFIS=+0x40 UFIS=+0x60)",lf), dwFIS
	mov ebx, dwFIS
	.if ebx < 100000h
	.endif
	ret
displayfis endp

displaycl proc uses ebx esi edi dwCL:dword
	invoke printf, CStr("      CL Base=0x%X, size=0x400 (32*32)",lf), dwCL
	mov ebx, dwCL
	cmp ebx, 100000h
	jnc exit
	xor edi,edi
	.while edi < 32
		movzx ecx,word ptr [ebx].CHStruct.flags1
		movzx edx, cl
		and dl,1Fh
		and cl,0e0h	;flags in cl: [5]A=ATAPI,[6]W=Write,[7]P=Prefetchable
		movzx eax,[ebx].CHStruct.PRDTL
		.if edx ;CFL must be > 0
			invoke printf, CStr("      CL[%u] PRDTL=%u CFL=%u flgs+PMP=0x%X PRDBC=0x%X (PRDTL=items in PRDT)",lf), edi, eax, edx, ecx, [ebx].CHStruct.PRDBC
			invoke printf, CStr("      CL[%u] Command Table Base Address=0x%lX (CFIS=+0 ACMD=+0x40 PRDT=+0x80)",lf), edi, qword ptr [ebx].CHStruct.CTBA0
			;--- is command table in conventional memory?
			.if [ebx].CHStruct.CTBA_U0 == 0 && [ebx].CHStruct.CTBA0 < 100000h
				mov esi, [ebx].CHStruct.CTBA0
				movzx eax,byte ptr [esi]
				invoke printf, CStr("        CFIS: type=0x%X",lf), eax
				add esi,80h
				movzx ecx, [ebx].CHStruct.PRDTL
				.while ecx
					push ecx
					invoke printf, CStr("        PRDT: 0x%lX 0x%X",lf), qword ptr [esi], dword ptr [esi+12]
					pop ecx
					add esi,4*4
					dec ecx
				.endw
			.endif
		.endif
		add ebx,32
		inc edi
	.endw
exit:
	ret
displaycl endp

;--- PxCMD:
;--- 0: ST - start, RW. 1=HBA may process command list
;--- 1: SUD - Spin Up Device
;--- 2: POD - Power On Device
;--- 3: CLO - Command List Overwrite. Software reset
;--- 4: FRE - FIS Receive Enable, RW. FISes may be written to FIS receive area (PxFB)
;--- 12-8: CCS - Current Command Slot, RO. 
;--- 13: MPSS - Mechanical Presence Switch State, RO.
;--- 14: FR - FIS Receive Running, RO.
;--- 15: CR - Command list Running, RO.
;--- 16: CPS - Cold Presence State, RO.
;--- 17: PMA - Port Multiplier Attached, RW if CAP.SPM=1.
;--- 18: HPCP - Hot Plug Capable Port, RO.
;--- 19: MPSP - Mechanical Presence Switch Attached to Port, RO.
;--- 20: CPD - Cold Presence Detection, RO.
;--- 21: ESP - External Sata Port, RO.
;--- 22: FBSCP - FIS-base Switching Capable Port, RO.
;--- 23: APSTE - Automatic Partial to Slumber Transitions Enabled, RW.
;--- 24: ATAPI - Device is ATAPI, RW.
;--- 25: DLAE - Drive LED on ATAPI Enable, RW.
;--- 26: ALPE - Aggressive Link Power Management Enable, RW.
;--- 27: ASP - Aggressive Slumber / Partial, RW.
;--- 31-28: ICC - Interface Communication Control, RW

displayport proc uses ebx esi dwPort:dword, dwPortAddr:dword, dwPhysAddr:dword
	mov ebx,dwPortAddr
	invoke printf, CStr("  Port %u, Base=0x%X",lf), dwPort, dwPhysAddr
	invoke printf, CStr("    CLB - Command List Base Address=0x%lX",lf), qword ptr [ebx+0]	; 1kB region
	invoke printf, CStr("    FB - FIS Base Address=0x%lX",lf), qword ptr [ebx+8]		;256 byte region
	invoke printf, CStr("    IS - Interrupt Status=0x%X ([0]=D2H Reg FIS, [1]=PIO Setup FIS, [2]=DMA Setup FIS, ...)",lf), dword ptr [ebx+10h]
	invoke printf, CStr("    IE - Interrupt Enable=0x%X",lf), dword ptr [ebx+14h]
	invoke printf, CStr("    CMD - Command and Status=0x%X",lf), dword ptr [ebx+18h]
	mov esi,[ebx+18h]
	xor eax,eax
	bt esi,4
	setc al
	invoke printf, CStr("    CMD.FRE[4]=%u (1=FISes may be written to FIS receive area)",lf), eax
	mov eax,esi
	shr eax,8
	and eax,1Fh
	invoke printf, CStr("    CMD.CCS[8-12]=%u (Current Command Slot)",lf), eax
	xor eax,eax
	bt esi,14
	setc al
	invoke printf, CStr("    CMD.FR[14]=%u (1=FIS receive running)",lf), eax
	xor eax,eax
	bt esi,15
	setc al
	invoke printf, CStr("    CMD.CR[15]=%u (1=Command List running)",lf), eax
	xor eax,eax
	bt esi,18
	setc al
	invoke printf, CStr("    CMD.HPCP[18]=%u (1=Hot Plug Capable Port)",lf), eax
	xor eax,eax
	bt esi,24
	setc al
	invoke printf, CStr("    CMD.ATAPI[24]=%u (1=device is ATAPI)",lf), eax
	invoke printf, CStr("    TFD - Task File Data=0x%X",lf), dword ptr [ebx+20h]

;--- signature: HDDs = 101h, CD/DVD=EB140101h, Port Multiplier=?
	invoke printf, CStr("    SIG - Signature=0x%X (received from device on first D2H register FIS)",lf), dword ptr [ebx+24h]

	mov eax,[ebx+28h]
	mov ecx,eax
	mov edx,eax
	shr ecx,4
	shr edx,8
	and eax,0Fh
	and ecx,0Fh
	and edx,0Fh
	push eax
	invoke printf, CStr("    SSTS - SATA Status=0x%X (Device Detection[3:0]=%u, Interface Speed[7:4]=%u, Power Management[11:8]=%u)",lf), dword ptr [ebx+28h], eax, ecx, edx
	mov eax,[ebx+2Ch]
	mov ecx,eax
	mov edx,eax
	shr ecx,4
	shr edx,8
	and eax,0Fh
	and ecx,0Fh
	and edx,0Fh
	invoke printf, CStr("    SCTL - SATA Control=0x%X (DET[3:0]=%u, SPD[7:4]=%u, IPM[11:8]=%u)",lf), dword ptr [ebx+2Ch], eax, ecx, edx
	invoke printf, CStr("    SERR - SATA Error=0x%X",lf), dword ptr [ebx+30h]
	invoke printf, CStr("    SACT - SATA Active=0x%X (bit string for max. 32 command slots)",lf), dword ptr [ebx+34h]
	invoke printf, CStr("    CI - Command Issued=0x%X (bit string for max. 32 command slots)",lf), dword ptr [ebx+38h]
	pop eax

	.if eax == 3 	;device detected and communication established?
		.if dword ptr [ebx+4] == 0
			invoke displaycl, dword ptr [ebx+0]
		.endif
		.if dword ptr [ebx+12] == 0
			invoke displayfis, dword ptr [ebx+8]
		.endif
	.endif
	ret
displayport endp

displayahci proc uses ebx esi edi dwPath:dword

local dwPhysBase:dword

	mov edi, 9*4
	mov ebx,dwPath
	mov ax,0B10Ah
	call int_1a
	jc exit
	mov esi, ecx
	mov dwPhysBase, ecx
	invoke printf, CStr("  AHCI Base Address=0x%X",lf), ecx
	push esi
	pop cx
	pop bx
	mov si,0000h
	mov di,1100h
	mov ax,0800h
	int 31h
	jc exit
	push bx
	push cx
	pop esi

;--- display HBA.CAP info
	mov ebx,[esi+0]
	invoke printf, CStr("  CAP - HBA Capabilities (RO): 0x%X",lf), ebx
	mov eax,ebx
	and eax,1Fh
	invoke printf, CStr("  CAP.NP[0-4]=%u (# of Ports-1)",lf),eax
	mov eax,ebx
	shr eax,8
	and eax,1Fh
	invoke printf, CStr("  CAP.NCS[8-12]=%u (# of Command Slots-1)",lf),eax
	xor eax,eax
	bt ebx,15
	setc al
	invoke printf, CStr("  CAP.PMD[15]=%u (1=supports multiple DRQ block data transfers for PIO)",lf),eax
	xor eax,eax
	bt ebx,18
	setc al
	invoke printf, CStr("  CAP.SAM[18]=%u (1=supports AHCI mode only)",lf),eax
	mov eax,ebx
	shr eax,20
	and eax,0Fh
	invoke printf, CStr("  CAP.ISS[20-23]=%u (Interface Speed Support, 1=1.5Gb,2=3Gb,...)",lf),eax
	xor eax,eax
	bt ebx,24
	setc al
	invoke printf, CStr("  CAP.SCLO[24]=%u (1=supports Command List Override)",lf),eax
	xor eax,eax
	bt ebx,30
	setc al
	invoke printf, CStr("  CAP.SNCQ[30]=%u (1=supports Native Command Queuing)",lf),eax
	xor eax,eax
	bt ebx,31
	setc al
	invoke printf, CStr("  CAP.S64A[31]=%u (1=supports 64-bit Addressing)",lf),eax

	mov ebx,[esi+4]
	invoke printf, CStr("  GHC - Global HBA Control: 0x%X",lf), ebx
	xor eax,eax
	bt ebx,31
	setc al
	invoke printf, CStr("  GHC.AE[31]=%u (1=AHCI Enable)",lf),eax

	invoke printf, CStr("  IS - Interrupt Status Register: 0x%X",lf), dword ptr [esi+8]
	invoke printf, CStr("  PI - Ports Implemented: 0x%X (is a DWORD bit-string, max. ports=32)",lf), dword ptr [esi+12]
	mov eax,dword ptr [esi+16]
	movzx ecx,al
	movzx edx,ah
	shr eax,16
	invoke printf, CStr("  VS - AHCI Version: %X.%X%X",lf), eax, edx, ecx
	mov ebx,[esi+12]
	mov edi,0
	.while ebx
		.if bl & 1
			mov ecx, dwPhysBase
			mov eax,edi
			shl eax,7
			lea ecx,[ecx+eax+100h]
			lea eax,[esi+eax+100h]
			invoke displayport, edi, eax, ecx
		.endif
		shr ebx,1
		inc edi
	.endw
exit:
	ret
displayahci endp

disppci proc uses ebx edi dwClass:dword, path:dword

local satacap:byte
local status:word

	mov ebx,path
	mov edi,0
	mov ax,0B10Ah
	call int_1a
	.if ah == 0
		movzx eax,cx
		shr ecx,16
		invoke printf, CStr("  vendor=0x%X, device=0x%X",lf), eax, ecx
	.endif
if 1
	mov edi,4		;PCI CMD
	mov ax,0B109h
	call int_1a
	.if ah == 0
		movzx ecx,cx
		invoke printf, CStr("  CMD=0x%X ([0]=IOSE,[1]=MSE (Memory Space Enable),[2]=BME (Bus Master Enable)",lf), ecx
	.endif
endif
	mov edi,6		;PCI STS (device status
	mov ax,0B109h
	call int_1a
	.if ah == 0
		mov status,cx
	.else
		mov status,0
	.endif

if 1
	mov edi,30h		;PCI EROM expansion ROM
	mov ax,0B10Ah
	call int_1a
	.if ah == 0
		invoke printf, CStr("  EROM=0x%X",lf), ecx
	.endif
endif


	mov satacap,0			
	.if status & 10h	;new capabilities present?
		mov edi,34h
		mov ax,0B108h
		call int_1a
		.if ah == 0
			movzx ecx,cl
			mov edi,ecx
			.repeat
				mov ax,0B109h
				call int_1a
				.break .if ah != 0
				movzx eax,ch
				movzx ecx,cl
				.if cl == 12h
					mov satacap,1
				.endif
				mov edi, eax
				invoke printf, CStr("  capabilities ID=0x%X, next pointer=0x%X",lf), ecx, eax
				.break .if edi == 0
			.until 0
		.endif
	.endif
	.if satacap
		invoke printf, CStr("  SATA capability register set found, Index-Data Pair (IDP) available",lf)
	.else
		invoke printf, CStr("  SATA capability register set not found, Index-Data Pair (IDP) not available",lf)
	.endif

	mov edi,3Ch
	mov ax,0B10Ah
	call int_1a
	.if ah == 0
		movzx eax,cl
		invoke printf, CStr("  interrupt line=%u",lf), eax
	.endif

	.if dwClass == 010601h
		invoke displayahci, ebx
	.endif
exit:
	ret
disppci endp

finddevice proc uses ebx esi edi dwClass:dword, pszType:ptr, bSilent:byte

	xor esi,esi
	.repeat
		mov ecx,dwClass
		mov ax,0B103h
		call int_1a
		.break .if ah != 0
		.if bVerbose
			movzx eax,ax
			invoke printf, CStr("Int 1ah, ax=B103h, ecx=%X, si=%u: ax=%X, ebx=%X",lf),dwClass,esi,eax,ebx
		.endif
		movzx eax,bh
		movzx ecx,bl
		shr ecx,3
		movzx edx,bl
		and dl,7
		invoke printf, CStr("%s device (class=0x%06X) found at bus/device/function=%u/%u/%u:",lf),pszType,dwClass,eax,ecx,edx
		invoke disppci, dwClass, ebx
		inc esi
	.until 0
	.if esi==0 && !bSilent
		invoke printf, CStr("no %s device (class=0x%06X) found",lf), pszType, dwClass
	.endif
	mov eax, esi
	ret

finddevice endp

main proc near c argc:dword,argv:dword,envp:dword

local dwClass:dword
local pszType:dword

	mov ax,100h
	mov bx,40h
	int 31h
	jc exit
	mov word ptr rmstack+0,400h
	mov word ptr rmstack+2,ax

	xor edi,edi
	mov ax,0B101h
	call int_1a
	movzx eax,ax
	.if bVerbose
		push edx
		push eax
		movzx ebx,bx
		movzx ecx,cl
		invoke printf, CStr("Int 1ah, ax=B101h: ax=%X (ok if ah=0), edi=%X (PM entry), edx=%X ('PCI'), bx=%X (Version), cl=%X (last bus)",lf),eax,edi,edx,ebx,ecx
		pop eax
		pop edx
	.endif
	cmp ah,0
	jnz error1
	cmp edx," ICP"
	jnz error1

;--- bits of PI:
;--- 0: 0=primary in compatibility mode,1=primary in native mode
;--- 1: 1=primary may be native or compat
;--- 2: 0=secondary in compatibility mode,1=secondary in native mode
;--- 3: 1=secondary may be native or compat
;--- 7: 1=busmaster device

	mov pszType, CStr("IDE Busmaster")
	mov dwClass, 010100h+80h	;search mass storage, IDE (+80h=busmaster)
	xor ebx,ebx
	.while byte ptr dwClass < 90h
		invoke finddevice, dwClass, pszType, 1
		add ebx,eax
		inc dwClass
	.endw
	.if !ebx
		invoke printf, CStr("no %s device (class=0x01018x) found",lf), pszType
	.endif

	mov pszType, CStr("SATA IDE")
	mov dwClass, 010600h	;search mass storage, SATA
	invoke finddevice, dwClass, pszType, 0

	mov pszType, CStr("SATA AHCI")
	mov dwClass, 010601h	;search mass storage, SATA, AHCI 
	invoke finddevice, dwClass, pszType, 0
exit:
	ret
error1:
	invoke printf, CStr("no PCI BIOS implemented",lf)
	ret
main endp

start32 proc c public
	call main
	mov ax,4c00h
	int 21h
start32 endp

	END start32

