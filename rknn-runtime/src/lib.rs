use anyhow::{anyhow, Result};
use std::fmt;
use std::path::{Path, PathBuf};

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum AiBackend {
    Auto,
    Cpu,
    Cuda,
    Coreml,
    Directml,
    Migraphx,
    Rk3588Hybrid,
}

impl AiBackend {
    pub fn parse(raw: &str) -> Result<Self> {
        match raw.trim().to_ascii_lowercase().as_str() {
            "" | "auto" => Ok(Self::Auto),
            "cpu" => Ok(Self::Cpu),
            "cuda" => Ok(Self::Cuda),
            "coreml" => Ok(Self::Coreml),
            "directml" => Ok(Self::Directml),
            "migraphx" => Ok(Self::Migraphx),
            "rk3588-hybrid" => Ok(Self::Rk3588Hybrid),
            other => Err(anyhow!(
                "unsupported AI backend '{other}', expected one of: auto, cpu, cuda, coreml, directml, migraphx, rk3588-hybrid"
            )),
        }
    }

    pub fn prefers_rknn(self) -> bool {
        matches!(self, Self::Rk3588Hybrid)
    }

    pub fn is_ort_gpu(self) -> bool {
        matches!(
            self,
            Self::Cuda | Self::Coreml | Self::Directml | Self::Migraphx
        )
    }

    pub fn as_str(self) -> &'static str {
        match self {
            Self::Auto => "auto",
            Self::Cpu => "cpu",
            Self::Cuda => "cuda",
            Self::Coreml => "coreml",
            Self::Directml => "directml",
            Self::Migraphx => "migraphx",
            Self::Rk3588Hybrid => "rk3588-hybrid",
        }
    }
}

impl fmt::Display for AiBackend {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str(self.as_str())
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Default)]
pub enum CoremlComputeUnits {
    #[default]
    All,
    CpuAndGpu,
    CpuAndNeuralEngine,
    CpuOnly,
}

impl CoremlComputeUnits {
    pub fn parse(raw: &str) -> Result<Self> {
        match raw.trim().to_ascii_lowercase().as_str() {
            "" | "all" => Ok(Self::All),
            "cpu-and-gpu" | "cpuandgpu" => Ok(Self::CpuAndGpu),
            "cpu-and-neural-engine" | "cpuandneuralengine" => Ok(Self::CpuAndNeuralEngine),
            "cpu-only" | "cpuonly" => Ok(Self::CpuOnly),
            other => Err(anyhow!(
                "unsupported AI_COREML_COMPUTE_UNITS '{other}', expected one of: all, cpu-and-gpu, cpu-and-neural-engine, cpu-only"
            )),
        }
    }

    pub fn as_str(self) -> &'static str {
        match self {
            Self::All => "all",
            Self::CpuAndGpu => "cpu-and-gpu",
            Self::CpuAndNeuralEngine => "cpu-and-neural-engine",
            Self::CpuOnly => "cpu-only",
        }
    }
}

impl fmt::Display for CoremlComputeUnits {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str(self.as_str())
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum TensorFormat {
    Nchw,
    Nhwc,
    Nc1hwc2,
    Undefined,
    Unknown(u32),
}

impl TensorFormat {
    pub fn from_raw(raw: u32) -> Self {
        match raw {
            0 => Self::Nchw,
            1 => Self::Nhwc,
            2 => Self::Nc1hwc2,
            3 => Self::Undefined,
            other => Self::Unknown(other),
        }
    }
}

#[derive(Debug, Clone)]
pub struct TensorSpec {
    pub index: usize,
    pub name: Option<String>,
    pub dims: Vec<usize>,
    pub element_count: usize,
    pub format: TensorFormat,
}

#[derive(Debug, Clone)]
pub struct TensorOutput {
    pub spec: TensorSpec,
    pub data: Vec<f32>,
}

impl TensorOutput {
    pub fn dims3(&self) -> Result<(usize, usize, usize)> {
        if self.spec.dims.len() != 3 {
            return Err(anyhow!("expected 3 output dims, got {:?}", self.spec.dims));
        }
        Ok((self.spec.dims[0], self.spec.dims[1], self.spec.dims[2]))
    }
}

#[cfg(all(target_os = "linux", target_arch = "aarch64"))]
mod supported {
    use super::{TensorFormat, TensorOutput, TensorSpec};
    use anyhow::{anyhow, Context, Result};
    use libloading::Library;
    use std::ffi::{c_char, c_void, CStr};
    use std::fs;
    use std::mem::{size_of, zeroed};
    use std::path::{Path, PathBuf};
    use std::ptr;
    use std::sync::{Arc, Mutex};

    const RKNN_QUERY_IN_OUT_NUM: u32 = 0;
    const RKNN_QUERY_INPUT_ATTR: u32 = 1;
    const RKNN_QUERY_OUTPUT_ATTR: u32 = 2;

    const RKNN_TENSOR_FLOAT32: u32 = 0;
    const RKNN_TENSOR_FLOAT16: u32 = 1;
    const RKNN_TENSOR_INT8: u32 = 2;
    const RKNN_TENSOR_UINT8: u32 = 3;
    const RKNN_TENSOR_INT16: u32 = 4;
    const RKNN_TENSOR_UINT16: u32 = 5;
    const RKNN_TENSOR_INT32: u32 = 6;

    type RknnContext = u64;

    #[repr(C)]
    #[derive(Clone, Copy)]
    struct RknnInputOutputNum {
        n_input: u32,
        n_output: u32,
    }

    #[repr(C)]
    #[derive(Clone, Copy)]
    struct RknnTensorAttr {
        index: u32,
        n_dims: u32,
        dims: [u32; 16],
        name: [c_char; 256],
        n_elems: u32,
        size: u32,
        fmt: u32,
        type_: u32,
        qnt_type: u32,
        fl: i8,
        zp: i32,
        scale: f32,
        w_stride: u32,
        size_with_stride: u32,
        pass_through: u8,
        h_stride: u32,
    }

    #[repr(C)]
    #[derive(Clone, Copy)]
    struct RknnInput {
        index: u32,
        buf: *mut c_void,
        size: u32,
        pass_through: u8,
        type_: u32,
        fmt: u32,
    }

    #[repr(C)]
    #[derive(Clone, Copy)]
    struct RknnOutput {
        want_float: u8,
        is_prealloc: u8,
        index: u32,
        buf: *mut c_void,
        size: u32,
    }

    type RknnInitFn =
        unsafe extern "C" fn(*mut RknnContext, *const c_void, u32, u32, *mut c_void) -> i32;
    type RknnQueryFn = unsafe extern "C" fn(RknnContext, u32, *mut c_void, u32) -> i32;
    type RknnInputsSetFn = unsafe extern "C" fn(RknnContext, u32, *mut RknnInput) -> i32;
    type RknnRunFn = unsafe extern "C" fn(RknnContext, *mut c_void) -> i32;
    type RknnOutputsGetFn =
        unsafe extern "C" fn(RknnContext, u32, *mut RknnOutput, *mut c_void) -> i32;
    type RknnOutputsReleaseFn = unsafe extern "C" fn(RknnContext, u32, *mut RknnOutput) -> i32;
    type RknnDestroyFn = unsafe extern "C" fn(RknnContext) -> i32;

    struct LibraryGuard(Library);

    // The dynamic library handle is only kept alive so loaded symbols remain valid.
    unsafe impl Send for LibraryGuard {}
    unsafe impl Sync for LibraryGuard {}

    struct Api {
        _lib: Arc<LibraryGuard>,
        rknn_init: RknnInitFn,
        rknn_query: RknnQueryFn,
        rknn_inputs_set: RknnInputsSetFn,
        rknn_run: RknnRunFn,
        rknn_outputs_get: RknnOutputsGetFn,
        rknn_outputs_release: RknnOutputsReleaseFn,
        rknn_destroy: RknnDestroyFn,
    }

    pub struct RknnRuntime {
        api: Arc<Api>,
        pub loaded_from: PathBuf,
    }

    struct ModelInner {
        api: Arc<Api>,
        context: RknnContext,
        input_specs: Vec<TensorSpec>,
        output_specs: Vec<TensorSpec>,
    }

    pub struct RknnModel {
        inner: Mutex<ModelInner>,
        pub model_path: PathBuf,
    }

    impl Drop for RknnModel {
        fn drop(&mut self) {
            if let Ok(mut inner) = self.inner.lock() {
                if inner.context != 0 {
                    unsafe {
                        (inner.api.rknn_destroy)(inner.context);
                    }
                    inner.context = 0;
                }
            }
        }
    }

    impl RknnRuntime {
        pub fn load(lib_path: Option<&Path>) -> Result<Self> {
            let candidate = lib_path
                .map(PathBuf::from)
                .or_else(|| std::env::var_os("RKNN_RUNTIME_LIB").map(PathBuf::from))
                .unwrap_or_else(|| PathBuf::from("librknnrt.so"));

            let library = unsafe { Library::new(&candidate) }.with_context(|| {
                format!(
                    "failed to load RKNN runtime library {}",
                    candidate.display()
                )
            })?;
            let guard = Arc::new(LibraryGuard(library));
            let api = unsafe {
                Arc::new(Api {
                    rknn_init: *guard.0.get(b"rknn_init\0")?,
                    rknn_query: *guard.0.get(b"rknn_query\0")?,
                    rknn_inputs_set: *guard.0.get(b"rknn_inputs_set\0")?,
                    rknn_run: *guard.0.get(b"rknn_run\0")?,
                    rknn_outputs_get: *guard.0.get(b"rknn_outputs_get\0")?,
                    rknn_outputs_release: *guard.0.get(b"rknn_outputs_release\0")?,
                    rknn_destroy: *guard.0.get(b"rknn_destroy\0")?,
                    _lib: guard,
                })
            };

            Ok(Self {
                api,
                loaded_from: candidate,
            })
        }

        pub fn load_model(&self, model_path: impl AsRef<Path>) -> Result<RknnModel> {
            let model_path = model_path.as_ref();
            let model_bytes = fs::read(model_path)
                .with_context(|| format!("failed to read RKNN model {}", model_path.display()))?;
            let mut context: RknnContext = 0;
            let rc = unsafe {
                (self.api.rknn_init)(
                    &mut context,
                    model_bytes.as_ptr().cast::<c_void>(),
                    model_bytes.len() as u32,
                    0,
                    ptr::null_mut(),
                )
            };
            if rc != 0 {
                return Err(anyhow!(
                    "rknn_init failed for {} with status {}",
                    model_path.display(),
                    rc
                ));
            }

            let (input_specs, output_specs) = query_model_specs(&self.api, context)?;
            Ok(RknnModel {
                inner: Mutex::new(ModelInner {
                    api: Arc::clone(&self.api),
                    context,
                    input_specs,
                    output_specs,
                }),
                model_path: model_path.to_path_buf(),
            })
        }
    }

    impl RknnModel {
        pub fn input_specs(&self) -> Vec<TensorSpec> {
            self.inner
                .lock()
                .expect("rknn model lock poisoned")
                .input_specs
                .clone()
        }

        pub fn output_specs(&self) -> Vec<TensorSpec> {
            self.inner
                .lock()
                .expect("rknn model lock poisoned")
                .output_specs
                .clone()
        }

        pub fn run_nchw_f32(
            &self,
            input_shape: &[usize],
            input_data: &[f32],
        ) -> Result<Vec<TensorOutput>> {
            let input_specs = self.input_specs();
            let spec = input_specs
                .first()
                .cloned()
                .context("RKNN model has no inputs")?;
            let (prepared, format) = prepare_nchw_input(&spec, input_shape, input_data)?;
            self.run_single_input_f32(&prepared, format)
        }

        pub fn run_tokens_i32(
            &self,
            input_shape: &[usize],
            input_data: &[i32],
        ) -> Result<Vec<TensorOutput>> {
            self.run_single_input_i32(input_shape, input_data)
        }

        pub fn run_tokens_i64(
            &self,
            input_shape: &[usize],
            input_data: &[i64],
        ) -> Result<Vec<TensorOutput>> {
            let mut converted = Vec::with_capacity(input_data.len());
            for &value in input_data {
                let narrowed = i32::try_from(value)
                    .with_context(|| format!("token value {value} exceeds i32 range"))?;
                converted.push(narrowed);
            }
            self.run_single_input_i32(input_shape, &converted)
        }

        fn run_single_input_f32(
            &self,
            input_data: &[f32],
            format: TensorFormat,
        ) -> Result<Vec<TensorOutput>> {
            let bytes = unsafe {
                std::slice::from_raw_parts(
                    input_data.as_ptr().cast::<u8>(),
                    input_data.len() * size_of::<f32>(),
                )
            };
            self.run_single_input_bytes(bytes, RKNN_TENSOR_FLOAT32, format)
        }

        fn run_single_input_i32(
            &self,
            _input_shape: &[usize],
            input_data: &[i32],
        ) -> Result<Vec<TensorOutput>> {
            let bytes = unsafe {
                std::slice::from_raw_parts(
                    input_data.as_ptr().cast::<u8>(),
                    input_data.len() * size_of::<i32>(),
                )
            };
            self.run_single_input_bytes(bytes, RKNN_TENSOR_INT32, TensorFormat::Undefined)
        }

        fn run_single_input_bytes(
            &self,
            input_bytes: &[u8],
            tensor_type: u32,
            format: TensorFormat,
        ) -> Result<Vec<TensorOutput>> {
            let mut inner = self.inner.lock().expect("rknn model lock poisoned");
            let format_raw = match format {
                TensorFormat::Nchw => 0,
                TensorFormat::Nhwc => 1,
                TensorFormat::Nc1hwc2 => 2,
                TensorFormat::Undefined | TensorFormat::Unknown(_) => 3,
            };
            let mut input = RknnInput {
                index: 0,
                buf: input_bytes.as_ptr().cast_mut().cast::<c_void>(),
                size: input_bytes.len() as u32,
                pass_through: 0,
                type_: tensor_type,
                fmt: format_raw,
            };

            let rc = unsafe { (inner.api.rknn_inputs_set)(inner.context, 1, &mut input) };
            if rc != 0 {
                return Err(anyhow!("rknn_inputs_set failed with status {}", rc));
            }

            let rc = unsafe { (inner.api.rknn_run)(inner.context, ptr::null_mut()) };
            if rc != 0 {
                return Err(anyhow!("rknn_run failed with status {}", rc));
            }

            let output_specs = inner.output_specs.clone();
            let mut outputs = vec![
                RknnOutput {
                    want_float: 1,
                    is_prealloc: 0,
                    index: 0,
                    buf: ptr::null_mut(),
                    size: 0,
                };
                output_specs.len()
            ];
            for (idx, output) in outputs.iter_mut().enumerate() {
                output.index = idx as u32;
            }

            let rc = unsafe {
                (inner.api.rknn_outputs_get)(
                    inner.context,
                    outputs.len() as u32,
                    outputs.as_mut_ptr(),
                    ptr::null_mut(),
                )
            };
            if rc != 0 {
                return Err(anyhow!("rknn_outputs_get failed with status {}", rc));
            }

            let converted = outputs
                .iter()
                .zip(output_specs.iter())
                .map(|(output, spec)| {
                    let len = spec.element_count;
                    let slice =
                        unsafe { std::slice::from_raw_parts(output.buf.cast::<f32>(), len) };
                    Ok(TensorOutput {
                        spec: spec.clone(),
                        data: slice.to_vec(),
                    })
                })
                .collect::<Result<Vec<_>>>()?;

            let rc = unsafe {
                (inner.api.rknn_outputs_release)(
                    inner.context,
                    outputs.len() as u32,
                    outputs.as_mut_ptr(),
                )
            };
            if rc != 0 {
                return Err(anyhow!("rknn_outputs_release failed with status {}", rc));
            }

            Ok(converted)
        }
    }

    fn query_model_specs(
        api: &Arc<Api>,
        context: RknnContext,
    ) -> Result<(Vec<TensorSpec>, Vec<TensorSpec>)> {
        let mut io_num = RknnInputOutputNum {
            n_input: 0,
            n_output: 0,
        };
        let rc = unsafe {
            (api.rknn_query)(
                context,
                RKNN_QUERY_IN_OUT_NUM,
                (&mut io_num as *mut RknnInputOutputNum).cast::<c_void>(),
                size_of::<RknnInputOutputNum>() as u32,
            )
        };
        if rc != 0 {
            return Err(anyhow!("rknn_query(IN_OUT_NUM) failed with status {}", rc));
        }

        let mut input_specs = Vec::with_capacity(io_num.n_input as usize);
        for index in 0..io_num.n_input {
            input_specs.push(query_tensor_spec(
                api,
                context,
                index,
                RKNN_QUERY_INPUT_ATTR,
            )?);
        }

        let mut output_specs = Vec::with_capacity(io_num.n_output as usize);
        for index in 0..io_num.n_output {
            output_specs.push(query_tensor_spec(
                api,
                context,
                index,
                RKNN_QUERY_OUTPUT_ATTR,
            )?);
        }

        Ok((input_specs, output_specs))
    }

    fn query_tensor_spec(
        api: &Arc<Api>,
        context: RknnContext,
        index: u32,
        query: u32,
    ) -> Result<TensorSpec> {
        let mut attr: RknnTensorAttr = unsafe { zeroed() };
        attr.index = index;
        let rc = unsafe {
            (api.rknn_query)(
                context,
                query,
                (&mut attr as *mut RknnTensorAttr).cast::<c_void>(),
                size_of::<RknnTensorAttr>() as u32,
            )
        };
        if rc != 0 {
            return Err(anyhow!(
                "rknn_query(attr {}) failed with status {}",
                index,
                rc
            ));
        }

        let dims = attr
            .dims
            .into_iter()
            .take(attr.n_dims as usize)
            .filter(|&dim| dim != 0)
            .map(|dim| dim as usize)
            .collect::<Vec<_>>();
        let name = unsafe { CStr::from_ptr(attr.name.as_ptr()) }
            .to_str()
            .ok()
            .map(str::trim)
            .filter(|name| !name.is_empty())
            .map(ToOwned::to_owned);
        let element_count = if attr.n_elems > 0 {
            attr.n_elems as usize
        } else if dims.is_empty() {
            0
        } else {
            dims.iter().product()
        };

        Ok(TensorSpec {
            index: index as usize,
            name,
            dims,
            element_count,
            format: TensorFormat::from_raw(attr.fmt),
        })
    }

    fn prepare_nchw_input(
        input_spec: &TensorSpec,
        input_shape: &[usize],
        input_data: &[f32],
    ) -> Result<(Vec<f32>, TensorFormat)> {
        if input_shape.len() != 4 {
            return Err(anyhow!(
                "expected NCHW input shape with 4 dims, got {:?}",
                input_shape
            ));
        }

        match input_spec.format {
            TensorFormat::Nhwc => {
                let (n, c, h, w) = (
                    input_shape[0],
                    input_shape[1],
                    input_shape[2],
                    input_shape[3],
                );
                let mut converted = vec![0.0f32; input_data.len()];
                for batch in 0..n {
                    for channel in 0..c {
                        for y in 0..h {
                            for x in 0..w {
                                let src = ((batch * c + channel) * h + y) * w + x;
                                let dst = ((batch * h + y) * w + x) * c + channel;
                                converted[dst] = input_data[src];
                            }
                        }
                    }
                }
                Ok((converted, TensorFormat::Nhwc))
            }
            _ => Ok((input_data.to_vec(), TensorFormat::Nchw)),
        }
    }
}

#[cfg(not(all(target_os = "linux", target_arch = "aarch64")))]
mod supported {
    use super::{TensorOutput, TensorSpec};
    use anyhow::{anyhow, Result};
    use std::path::{Path, PathBuf};

    pub struct RknnRuntime {
        pub loaded_from: PathBuf,
    }

    pub struct RknnModel {
        pub model_path: PathBuf,
    }

    impl RknnRuntime {
        pub fn load(_lib_path: Option<&Path>) -> Result<Self> {
            Err(anyhow!(
                "RKNN runtime is only supported on Linux aarch64 targets"
            ))
        }

        pub fn load_model(&self, _model_path: impl AsRef<Path>) -> Result<RknnModel> {
            Err(anyhow!(
                "RKNN runtime is only supported on Linux aarch64 targets"
            ))
        }
    }

    impl RknnModel {
        pub fn input_specs(&self) -> Vec<TensorSpec> {
            Vec::new()
        }

        pub fn output_specs(&self) -> Vec<TensorSpec> {
            Vec::new()
        }

        pub fn run_nchw_f32(
            &self,
            _input_shape: &[usize],
            _input_data: &[f32],
        ) -> Result<Vec<TensorOutput>> {
            Err(anyhow!(
                "RKNN runtime is only supported on Linux aarch64 targets"
            ))
        }

        pub fn run_tokens_i32(
            &self,
            _input_shape: &[usize],
            _input_data: &[i32],
        ) -> Result<Vec<TensorOutput>> {
            Err(anyhow!(
                "RKNN runtime is only supported on Linux aarch64 targets"
            ))
        }

        pub fn run_tokens_i64(
            &self,
            _input_shape: &[usize],
            _input_data: &[i64],
        ) -> Result<Vec<TensorOutput>> {
            Err(anyhow!(
                "RKNN runtime is only supported on Linux aarch64 targets"
            ))
        }
    }
}

pub use supported::{RknnModel, RknnRuntime};

pub fn runtime_override_from_env() -> Option<PathBuf> {
    std::env::var_os("RKNN_RUNTIME_LIB").map(PathBuf::from)
}

pub fn coreml_compute_units_from_env_or_default() -> CoremlComputeUnits {
    std::env::var("AI_COREML_COMPUTE_UNITS")
        .ok()
        .and_then(|raw| CoremlComputeUnits::parse(&raw).ok())
        .unwrap_or_default()
}

pub fn default_library_name() -> &'static Path {
    Path::new("librknnrt.so")
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn parses_coreml_backend() {
        assert_eq!(AiBackend::parse("coreml").unwrap(), AiBackend::Coreml);
    }

    #[test]
    fn parses_coreml_compute_units() {
        assert_eq!(
            CoremlComputeUnits::parse("cpu-and-gpu").unwrap(),
            CoremlComputeUnits::CpuAndGpu
        );
        assert_eq!(
            CoremlComputeUnits::parse("cpu-and-neural-engine").unwrap(),
            CoremlComputeUnits::CpuAndNeuralEngine
        );
        assert_eq!(
            CoremlComputeUnits::parse("cpu-only").unwrap(),
            CoremlComputeUnits::CpuOnly
        );
        assert_eq!(
            CoremlComputeUnits::parse("all").unwrap(),
            CoremlComputeUnits::All
        );
    }

    #[test]
    fn rejects_invalid_coreml_compute_units() {
        let err = CoremlComputeUnits::parse("gpu-only").unwrap_err();
        assert!(
            err.to_string().contains("AI_COREML_COMPUTE_UNITS"),
            "unexpected error: {err}"
        );
    }
}
