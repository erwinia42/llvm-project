; RUN: opt %loadNPMPolly '-passes=polly-custom<codegen>' -aa-pipeline=basic-aa,scoped-noalias-aa -plugin-arg=Polly,-polly-process-unprofitable -verify-each -S < %s | FileCheck %s
; RUN: opt %loadNPMPolly '-passes=polly-custom<codegen>' -aa-pipeline=basic-aa,scoped-noalias-aa -plugin-arg=Polly,-polly-process-unprofitable -plugin-arg=Polly,-polly-allow-modref-calls -verify-each -S < %s | FileCheck %s

; RUN: opt %loadNPMPolly '-passes=polly-custom<codegen>' -aa-pipeline=basic-aa,scoped-noalias-aa -plugin-arg=Polly,-polly-process-unprofitable -plugin-arg=Polly,-polly-use-runtime-alias-checks=false -verify-each -S < %s | FileCheck %s --check-prefix=NORTC

; Region-local scopes cannot prove that whole arrays are disjoint across
; iterations. Preserve the original annotations on the fallback path, and
; filter local scopes before alias analysis and before cloning instructions.

target datalayout = "e-m:e-i64:64-f80:128-n8:16:32:64-S128"

declare void @llvm.experimental.noalias.scope.decl(metadata)
declare void @llvm.memcpy.p0.p0.i64(ptr, ptr, i64, i1 immarg)
declare void @read_memory(ptr) memory(argmem: read) nounwind willreturn

; Local load/store scopes require a runtime check. With checks disabled,
; detection must reject the region even with scoped-noalias AA enabled.
; CHECK-LABEL: define void @local_load_store(
; CHECK: icmp ule i64
; CHECK: call void @llvm.experimental.noalias.scope.decl(metadata ![[LOCAL:[0-9]+]])
; CHECK: load i32, ptr %s, align 4, !alias.scope ![[LOCAL]]
; CHECK: store i32 %v, ptr %d, align 4, !noalias ![[LOCAL]]
; CHECK: polly.start:
; CHECK-NOT: call void @llvm.experimental.noalias.scope.decl
; CHECK: load i32, ptr %{{.*}}, align 4, !alias.scope
; CHECK: store i32
; CHECK-NOT: call void @llvm.experimental.noalias.scope.decl
; CHECK: }
; NORTC-LABEL: define void @local_load_store(
; NORTC-NOT: polly.start:
; NORTC: }
define void @local_load_store(ptr %dst, ptr %src) {
entry:
  br label %loop

loop:
  %i = phi i64 [0, %entry], [%next, %body]
  %cmp = icmp ult i64 %i, 64
  br i1 %cmp, label %body, label %exit

body:
  call void @llvm.experimental.noalias.scope.decl(metadata !0)
  %s = getelementptr inbounds i32, ptr %src, i64 %i
  %d = getelementptr inbounds i32, ptr %dst, i64 %i
  %v = load i32, ptr %s, align 4, !alias.scope !0
  store i32 %v, ptr %d, align 4, !noalias !0
  %next = add nuw nsw i64 %i, 1
  br label %loop

exit:
  ret void
}

; Both memory-transfer pointers must participate in the runtime alias check.
; The cloned intrinsic loses local tags while the fallback retains them.
; CHECK-LABEL: define void @local_memcpy(
; CHECK: icmp ule i64
; CHECK: call void @llvm.experimental.noalias.scope.decl(metadata ![[LOCAL]])
; CHECK: call void @llvm.memcpy{{.*}}!noalias ![[LOCAL]]
; CHECK: polly.start:
; CHECK-NOT: call void @llvm.experimental.noalias.scope.decl
; CHECK: call void @llvm.memcpy{{.*}}i1 false){{$}}
; CHECK-NOT: call void @llvm.experimental.noalias.scope.decl
; CHECK: }
; NORTC-LABEL: define void @local_memcpy(
; NORTC-NOT: polly.start:
; NORTC: }
define void @local_memcpy(ptr %dst, ptr %src) {
entry:
  br label %loop

loop:
  %i = phi i64 [0, %entry], [%next, %body]
  %cmp = icmp ult i64 %i, 64
  br i1 %cmp, label %body, label %exit

body:
  call void @llvm.experimental.noalias.scope.decl(metadata !0)
  %s = getelementptr inbounds i32, ptr %src, i64 %i
  %d = getelementptr inbounds i32, ptr %dst, i64 %i
  call void @llvm.memcpy.p0.p0.i64(ptr %d, ptr %s, i64 4, i1 false), !noalias !0
  %next = add nuw nsw i64 %i, 1
  br label %loop

exit:
  ret void
}

; Mixed lists retain the externally declared scope on the cloned intrinsic.
; CHECK-LABEL: define void @mixed_memcpy(
; CHECK: call void @llvm.experimental.noalias.scope.decl(metadata ![[EXTERNAL:[0-9]+]])
; CHECK: polly.start:
; CHECK-NOT: call void @llvm.experimental.noalias.scope.decl
; CHECK: call void @llvm.memcpy{{.*}}!alias.scope ![[EXTERNAL]]{{$}}
; CHECK: }
define void @mixed_memcpy(ptr %dst, ptr %src) {
entry:
  call void @llvm.experimental.noalias.scope.decl(metadata !3)
  br label %loop

loop:
  %i = phi i64 [0, %entry], [%next, %body]
  %cmp = icmp ult i64 %i, 64
  br i1 %cmp, label %body, label %exit

body:
  call void @llvm.experimental.noalias.scope.decl(metadata !0)
  %s = getelementptr inbounds i32, ptr %src, i64 %i
  %d = getelementptr inbounds i32, ptr %dst, i64 %i
  call void @llvm.memcpy.p0.p0.i64(ptr %d, ptr %s, i64 4, i1 false), !alias.scope !6
  %next = add nuw nsw i64 %i, 1
  br label %loop

exit:
  ret void
}

; A scope declared outside the region remains usable for alias proofs.
; CHECK-LABEL: define void @external_load_store(
; CHECK: call void @llvm.experimental.noalias.scope.decl(metadata ![[EXTERNAL]])
; CHECK: br i1 true, label %polly.start
; CHECK: polly.start:
; NORTC-LABEL: define void @external_load_store(
; NORTC: br i1 true, label %polly.start
; NORTC: polly.start:
define void @external_load_store(ptr %dst, ptr %src) {
entry:
  call void @llvm.experimental.noalias.scope.decl(metadata !3)
  br label %loop

loop:
  %i = phi i64 [0, %entry], [%next, %body]
  %cmp = icmp ult i64 %i, 64
  br i1 %cmp, label %body, label %exit

body:
  %s = getelementptr inbounds i32, ptr %src, i64 %i
  %d = getelementptr inbounds i32, ptr %dst, i64 %i
  %v = load i32, ptr %s, align 4, !alias.scope !3
  store i32 %v, ptr %d, align 4, !noalias !3
  %next = add nuw nsw i64 %i, 1
  br label %loop

exit:
  ret void
}

; Reject declarations whose scope is used outside the region.
; CHECK-LABEL: define void @escaping_scope(
; CHECK-NOT: polly.start:
; CHECK: }
define void @escaping_scope(ptr %dst, ptr %src) {
entry:
  br label %loop

loop:
  %i = phi i64 [0, %entry], [%next, %body]
  %cmp = icmp ult i64 %i, 64
  br i1 %cmp, label %body, label %exit

body:
  call void @llvm.experimental.noalias.scope.decl(metadata !0)
  %s = getelementptr inbounds i32, ptr %src, i64 %i
  %d = getelementptr inbounds i32, ptr %dst, i64 %i
  %v = load i32, ptr %s, align 4, !alias.scope !0
  store i32 %v, ptr %d, align 4, !noalias !0
  %next = add nuw nsw i64 %i, 1
  br label %loop

exit:
  store i32 0, ptr %dst, !noalias !0
  ret void
}

; Reject memory-accessing calls with local tags even with mod/ref support.
; CHECK-LABEL: define void @local_call(
; CHECK-NOT: polly.start:
; CHECK: }
define void @local_call(ptr %dst, ptr %src) {
entry:
  br label %loop

loop:
  %i = phi i64 [0, %entry], [%next, %body]
  %cmp = icmp ult i64 %i, 64
  br i1 %cmp, label %body, label %exit

body:
  call void @llvm.experimental.noalias.scope.decl(metadata !0)
  %s = getelementptr inbounds i32, ptr %src, i64 %i
  %d = getelementptr inbounds i32, ptr %dst, i64 %i
  call void @read_memory(ptr %s), !noalias !0
  %v = load i32, ptr %s, align 4, !alias.scope !0
  store i32 %v, ptr %d, align 4, !noalias !0
  %next = add nuw nsw i64 %i, 1
  br label %loop

exit:
  ret void
}

!0 = !{!1}
!1 = distinct !{!1, !2, !"local scope"}
!2 = distinct !{!2, !"local domain"}
!3 = !{!4}
!4 = distinct !{!4, !5, !"external scope"}
!5 = distinct !{!5, !"external domain"}
!6 = !{!1, !4}
