// dobby sends hooked function n to thunk n, which saves the registers and calls the original
// between phigrospp_enter and phigrospp_leave, so lua can read the arguments and change the result.
// when phigrospp_enter returns true a skip hook skipped the original, its zeroed result is already in place

// stack frame layout, from sp
#define STACK_ARGS 0 // 64 bytes of the caller's stack arguments, pushed again for the original
#define X 64         // x0-x8
#define V 144        // q0-q7
#define ID 272
#define SLOT 280     // 24 bytes kept from phigrospp_enter to phigrospp_leave
#define FRAME 304

    .text
    .p2align 3
    .globl phigrospp_thunks
    .hidden phigrospp_thunks
phigrospp_thunks:
    .set id, 0
    .rept THUNKS
    mov x16, #id
    b common
    .set id, id + 1
    .endr

common:
    stp x29, x30, [sp, #-16]!
    mov x29, sp
    sub sp, sp, #FRAME

    stp x0, x1, [sp, #X]
    stp x2, x3, [sp, #X + 16]
    stp x4, x5, [sp, #X + 32]
    stp x6, x7, [sp, #X + 48]
    str x8, [sp, #X + 64]
    stp q0, q1, [sp, #V]
    stp q2, q3, [sp, #V + 32]
    stp q4, q5, [sp, #V + 64]
    stp q6, q7, [sp, #V + 96]
    str x16, [sp, #ID]

    mov x0, x16
    add x1, sp, #X
    add x2, sp, #V
    add x3, sp, #SLOT
    bl phigrospp_enter
    cbnz w0, done

    add x9, x29, #16 // the caller's sp
    ldp x10, x11, [x9]
    stp x10, x11, [sp, #STACK_ARGS]
    ldp x10, x11, [x9, #16]
    stp x10, x11, [sp, #STACK_ARGS + 16]
    ldp x10, x11, [x9, #32]
    stp x10, x11, [sp, #STACK_ARGS + 32]
    ldp x10, x11, [x9, #48]
    stp x10, x11, [sp, #STACK_ARGS + 48]

    ldp x0, x1, [sp, #X]
    ldp x2, x3, [sp, #X + 16]
    ldp x4, x5, [sp, #X + 32]
    ldp x6, x7, [sp, #X + 48]
    ldr x8, [sp, #X + 64]
    ldp q0, q1, [sp, #V]
    ldp q2, q3, [sp, #V + 32]
    ldp q4, q5, [sp, #V + 64]
    ldp q6, q7, [sp, #V + 96]
    ldr x16, [sp, #ID]
    adrp x17, phigrospp_originals
    add x17, x17, :lo12:phigrospp_originals
    ldr x17, [x17, x16, lsl #3]
    blr x17

    // the return registers go where the arguments were, so phigrospp_leave reads them the same way
    stp x0, x1, [sp, #X]
    stp q0, q1, [sp, #V]
    stp q2, q3, [sp, #V + 32]
    ldr x0, [sp, #ID]
    add x1, sp, #X
    add x2, sp, #V
    add x3, sp, #SLOT
    bl phigrospp_leave

done:
    ldp x0, x1, [sp, #X]
    ldp q0, q1, [sp, #V]
    ldp q2, q3, [sp, #V + 32]
    add sp, sp, #FRAME
    ldp x29, x30, [sp], #16
    ret
