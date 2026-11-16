import Accelerate
import Foundation

/// 任意长度的离散傅里叶变换，给「听声音的引擎」的纯计算用（docs/architecture/listening-engine.md）。
///
/// 管什么：长度 n 的复数 DFT（不归一，指数 −2πi·kt/n，和 numpy 同号）；实数进、取前 n/2+1 个频点（numpy 的 `rfft`）；
/// 从频点回到长度 n 的实数序列（numpy 的 `irfft(Y, n)`：多的截掉、少的补零，直流和偶数长度的最高频点只取实部）。
/// 不管什么：加窗、取模、分带（在用它的文件里）；重采样（`ListeningResample`）。
///
/// 为什么不直接用 vDSP：它的 DFT 只认 f × 2^k（f 是 1、3、5、15）几种长度，可这里的长度由句子有多长决定
/// （整句一次重采样到 10 kHz），原声特征的窗又是研究时定的 1488 点。vDSP 认的长度直接交给它；别的走 Bluestein（chirp-z）：
/// 把 DFT 改写成一次卷积，卷积用 2 的幂长度的 vDSP DFT 做。全程双精度，和 numpy 的 pocketfft 差在 1e-12 量级。
///
/// 一个实例只管一种长度，建好以后只读，几个线程可以同时用。
final class ListeningDFT {
    let length: Int
    /// 直接变换时是长度 n 的那一个；Bluestein 时是卷积用的 2 的幂长度的那一个。
    private let setup: OpaquePointer
    /// nil = vDSP 直接认这个长度。
    private let chirp: Chirp?

    init(length: Int) {
        precondition(length > 0, "DFT 的长度至少是 1")
        self.length = length
        if let direct = vDSP_DFT_zop_CreateSetupD(nil, vDSP_Length(length), .FORWARD) {
            setup = direct
            chirp = nil
        } else {
            var m = 8
            while m < 2 * length - 1 { m *= 2 }
            guard let convolution = vDSP_DFT_zop_CreateSetupD(nil, vDSP_Length(m), .FORWARD) else {
                preconditionFailure("vDSP 不认 2 的幂长度 \(m)")
            }
            setup = convolution
            chirp = Chirp(length: length, convolutionLength: m, setup: convolution)
        }
    }

    deinit { vDSP_DFT_DestroySetupD(setup) }

    /// 复数 DFT：X_k = Σ x_t·e^(−2πi·kt/n)，不归一。
    func forward(re: [Double], im: [Double]) -> (re: [Double], im: [Double]) {
        precondition(re.count == length && im.count == length, "输入长度和 DFT 的长度不一样")
        guard let chirp else { return ListeningDFT.execute(setup, re, im) }
        return chirp.transform(re, im, setup: setup)
    }

    /// numpy 的 `rfft(x)`：前 n/2+1 个频点。
    func realForward(_ x: [Double]) -> (re: [Double], im: [Double]) {
        let full = forward(re: x, im: [Double](repeating: 0, count: length))
        let bins = length / 2 + 1
        return (Array(full.re.prefix(bins)), Array(full.im.prefix(bins)))
    }

    /// numpy 的 `irfft(Y, n: length)`：先补成共轭对称的整条频谱，再做反变换。
    /// 实数序列 x = IDFT(Z) = Re(DFT(conj Z)) / n，所以只用正向的那一个 setup。
    func realInverse(re: [Double], im: [Double]) -> [Double] {
        precondition(re.count == im.count, "实部、虚部的长度不一样")
        let n = length
        let given = re.count
        var zr = [Double](repeating: 0, count: n)
        var zi = [Double](repeating: 0, count: n)
        if given > 0 { zr[0] = re[0] }
        var k = 1
        while 2 * k < n {   // 1 ≤ k < n/2：两头成对
            if k < given {
                zr[k] = re[k]; zi[k] = -im[k]          // conj(Z_k)
                zr[n - k] = re[k]; zi[n - k] = im[k]   // conj(Z_(n−k)) = Z_k
            }
            k += 1
        }
        if n % 2 == 0, n / 2 < given, n > 1 { zr[n / 2] = re[n / 2] }   // 偶数长度的最高频点只取实部
        let out = forward(re: zr, im: zi)
        let scale = 1 / Double(n)
        return out.re.map { $0 * scale }
    }

    fileprivate static func execute(_ setup: OpaquePointer, _ re: [Double], _ im: [Double]) -> ([Double], [Double]) {
        var outRe = [Double](repeating: 0, count: re.count)
        var outIm = [Double](repeating: 0, count: re.count)
        vDSP_DFT_ExecuteD(setup, re, im, &outRe, &outIm)
        return (outRe, outIm)
    }
}

/// Bluestein：kt = (k² + t² − (k − t)²) / 2，所以 X_k = w_k · Σ_t (x_t·w_t)·conj(w_(k−t))，w_t = e^(−iπ·t²/n)。
/// 右边是长度 n 的序列和 conj(w) 的卷积，补零到 m ≥ 2n − 1 以后用 m 点的 DFT 做循环卷积。
private struct Chirp {
    let convolutionLength: Int
    let wr: [Double], wi: [Double]   // w_t，t < n
    let kr: [Double], ki: [Double]   // conj(DFT_m(b))，b = conj(w) 两头绕回去；存共轭，下面少一次取负

    init(length n: Int, convolutionLength m: Int, setup: OpaquePointer) {
        convolutionLength = m
        var wr = [Double](repeating: 0, count: n)
        var wi = [Double](repeating: 0, count: n)
        for t in 0..<n {
            // t² 先对 2n 取模（整数，精确），角度一直在 [0, 2π)：直接算 π·t²/n 的话 t 一大就丢精度。
            let r = (t * t) % (2 * n)
            let angle = Double.pi * Double(r) / Double(n)
            wr[t] = cos(angle)
            wi[t] = -sin(angle)
        }
        var br = [Double](repeating: 0, count: m)
        var bi = [Double](repeating: 0, count: m)
        br[0] = wr[0]; bi[0] = -wi[0]
        for t in 1..<max(n, 1) {
            br[t] = wr[t]; bi[t] = -wi[t]
            br[m - t] = wr[t]; bi[m - t] = -wi[t]
        }
        let (fr, fi) = ListeningDFT.execute(setup, br, bi)
        self.wr = wr
        self.wi = wi
        kr = fr
        ki = fi.map { -$0 }
    }

    func transform(_ xr: [Double], _ xi: [Double], setup: OpaquePointer) -> ([Double], [Double]) {
        let n = wr.count
        let m = convolutionLength
        var ar = [Double](repeating: 0, count: m)
        var ai = [Double](repeating: 0, count: m)
        for t in 0..<n {
            ar[t] = xr[t] * wr[t] - xi[t] * wi[t]
            ai[t] = xr[t] * wi[t] + xi[t] * wr[t]
        }
        var (fr, fi) = ListeningDFT.execute(setup, ar, ai)
        // 循环卷积 = IDFT(A·B) = conj(DFT(conj(A·B))) / m；conj(A·B) = conj(A)·conj(B)，conj(B) 就是存着的 k。
        for j in 0..<m {
            let pr = fr[j] * kr[j] + fi[j] * ki[j]   // conj(A)·kc 的实部：(a − ib)(c + id) → ac + bd
            let pi = fr[j] * ki[j] - fi[j] * kr[j]   //                    虚部：ad − bc
            fr[j] = pr
            fi[j] = pi
        }
        let (cr, ci) = ListeningDFT.execute(setup, fr, fi)
        let scale = 1 / Double(m)
        var outRe = [Double](repeating: 0, count: n)
        var outIm = [Double](repeating: 0, count: n)
        for k in 0..<n {
            let vr = cr[k] * scale
            let vi = -ci[k] * scale
            outRe[k] = vr * wr[k] - vi * wi[k]
            outIm[k] = vr * wi[k] + vi * wr[k]
        }
        return (outRe, outIm)
    }
}
