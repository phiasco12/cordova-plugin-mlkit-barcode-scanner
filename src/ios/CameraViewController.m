@import AVFoundation;
@import MLKitBarcodeScanning;
@import MLKitVision;

#import "CameraViewController.h"

@interface CameraViewController ()<AVCaptureVideoDataOutputSampleBufferDelegate>
@property(nonatomic, strong) AVCaptureSession *session;
@property(nonatomic, strong) AVCaptureVideoPreviewLayer *previewLayer;
@property(nonatomic, strong) AVCaptureVideoDataOutput *videoDataOutput;
@property(nonatomic, strong) dispatch_queue_t videoDataOutputQueue;
@property(nonatomic, strong) MLKBarcodeScanner *barcodeDetector;
@property(nonatomic, strong) UIButton *torchButton;

@property(nonatomic, strong) NSMutableArray<NSString *> *recentDetections;
@property(nonatomic, assign) NSInteger requiredStableCount;
@property(nonatomic, assign) BOOL processingFrame;

@property(nonatomic, strong) UIView *scanBox;
@property(nonatomic, strong) UIView *scanLine;

// Normalized crop region (0–1 coordinates)
@property(nonatomic, assign) CGRect normalizedScanRect;
@end

@implementation CameraViewController
@synthesize delegate;

- (BOOL)prefersStatusBarHidden { return YES; }
- (BOOL)prefersHomeIndicatorAutoHidden { return YES; }
- (BOOL) shouldAutorotate { return NO; }
- (UIInterfaceOrientationMask)supportedInterfaceOrientations { return UIInterfaceOrientationMaskPortrait; }

- (id)initWithCoder:(NSCoder *)aDecoder {
    self = [super initWithCoder:aDecoder];
    if (self) {
        _videoDataOutputQueue = dispatch_queue_create("VideoDataOutputQueue", DISPATCH_QUEUE_SERIAL);
        _recentDetections = [NSMutableArray array];
        _requiredStableCount = 3;
        _processingFrame = NO;
    }
    return self;
}

- (void)viewDidLoad {
    [super viewDidLoad];

    self.session = [[AVCaptureSession alloc] init];
    self.session.sessionPreset = AVCaptureSessionPreset1920x1080;

    [self updateCameraSelection];
    [self setUpVideoProcessing];
    [self setUpCameraPreview];

    NSNumber *formats = 0;
    if([_barcodeFormats  isEqual: @0]) {
        formats = @(MLKBarcodeFormatCode39|MLKBarcodeFormatDataMatrix);
    } else {
        formats = _barcodeFormats;
    }

    MLKBarcodeScannerOptions *options = [[MLKBarcodeScannerOptions alloc] initWithFormats:[formats intValue]];
    self.barcodeDetector = [MLKBarcodeScanner barcodeScannerWithOptions:options];
}

- (void)viewDidAppear:(BOOL)animated {
    [super viewDidAppear:animated];
    [[UIDevice currentDevice] setValue:@(UIInterfaceOrientationPortrait) forKey:@"orientation"];
    [self.session startRunning];
    [self startScanLineAnimation];
}

- (void)viewDidDisappear:(BOOL)animated {
    [super viewDidDisappear:animated];
    [self.session stopRunning];
}

#pragma mark - Video Output Delegate
- (void)captureOutput:(AVCaptureOutput *)output didOutputSampleBuffer:(CMSampleBufferRef)sampleBuffer fromConnection:(AVCaptureConnection *)connection {

    if (self.processingFrame) return;
    self.processingFrame = YES;

    // Get pixel buffer and crop to ROI
    CVImageBufferRef buffer = CMSampleBufferGetImageBuffer(sampleBuffer);
    if (!buffer) { self.processingFrame = NO; return; }

    CVPixelBufferLockBaseAddress(buffer, kCVPixelBufferLock_ReadOnly);
    size_t width = CVPixelBufferGetWidth(buffer);
    size_t height = CVPixelBufferGetHeight(buffer);

    // Translate normalized rect to pixel coordinates
    CGRect roi = CGRectMake(self.normalizedScanRect.origin.x * width,
                            self.normalizedScanRect.origin.y * height,
                            self.normalizedScanRect.size.width * width,
                            self.normalizedScanRect.size.height * height);

    // Clamp ROI
    roi.origin.x = MAX(0, MIN(width - roi.size.width, roi.origin.x));
    roi.origin.y = MAX(0, MIN(height - roi.size.height, roi.origin.y));

    CIImage *ciImage = [CIImage imageWithCVPixelBuffer:buffer];
    CIImage *cropped = [ciImage imageByCroppingToRect:roi];

    CVPixelBufferUnlockBaseAddress(buffer, kCVPixelBufferLock_ReadOnly);

    MLKVisionImage *visionImage = [[MLKVisionImage alloc] initWithImage:[self uiImageFromCIImage:cropped]];
    visionImage.orientation = [self imageOrientationForDevice];

    [self.barcodeDetector processImage:visionImage completion:^(NSArray<MLKBarcode *> *barcodes, NSError *error) {
        self.processingFrame = NO;

        if (error || barcodes.count == 0) return;

        for (MLKBarcode *barcode in barcodes) {
            NSString *value = [[barcode.rawValue stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]] uppercaseString];
            if (!value.length) continue;

            // Regex filter example (adjust as needed)
            NSRegularExpression *regex = [NSRegularExpression regularExpressionWithPattern:@"^RF[0-9]{5,6}$" options:0 error:nil];
            if ([regex numberOfMatchesInString:value options:0 range:NSMakeRange(0, value.length)] == 0) continue;

            [self.recentDetections addObject:value];
            if (self.recentDetections.count > 10) [self.recentDetections removeObjectAtIndex:0];

            NSMutableDictionary *freq = [NSMutableDictionary dictionary];
            for (NSString *v in self.recentDetections) freq[v] = @([freq[v] intValue] + 1);

            NSString *best = nil; NSInteger max = 0;
            for (NSString *k in freq) if ([freq[k] intValue] > max) { best = k; max = [freq[k] intValue]; }

            if (max >= self.requiredStableCount && [value isEqualToString:best]) {
                dispatch_async(dispatch_get_main_queue(), ^{
                    [self.session stopRunning];
                    [self->delegate sendResult:barcode];
                });
                return;
            }
        }
    }];
}

#pragma mark - Orientation
- (UIImageOrientation)imageOrientationForDevice {
    UIDeviceOrientation o = UIDevice.currentDevice.orientation;
    switch (o) {
        case UIDeviceOrientationPortraitUpsideDown: return UIImageOrientationLeft;
        case UIDeviceOrientationLandscapeLeft: return UIImageOrientationUp;
        case UIDeviceOrientationLandscapeRight: return UIImageOrientationDown;
        default: return UIImageOrientationRight;
    }
}

#pragma mark - Camera setup
- (void)setUpVideoProcessing {
    self.videoDataOutput = [[AVCaptureVideoDataOutput alloc] init];
    NSDictionary *settings = @{(__bridge NSString*)kCVPixelBufferPixelFormatTypeKey : @(kCVPixelFormatType_32BGRA)};
    [self.videoDataOutput setVideoSettings:settings];
    [self.videoDataOutput setAlwaysDiscardsLateVideoFrames:YES];
    [self.videoDataOutput setSampleBufferDelegate:self queue:self.videoDataOutputQueue];
    if ([self.session canAddOutput:self.videoDataOutput]) [self.session addOutput:self.videoDataOutput];
}

- (void)setUpCameraPreview {
    self.previewLayer = [[AVCaptureVideoPreviewLayer alloc] initWithSession:self.session];
    self.previewLayer.videoGravity = AVLayerVideoGravityResizeAspectFill;
    self.previewLayer.frame = self.view.bounds;
    [self.view.layer addSublayer:self.previewLayer];

    CGRect screen = UIScreen.mainScreen.bounds;
    CGFloat w = screen.size.width * _scanAreaSize;
    CGFloat h = w;
    CGFloat x = (screen.size.width - w) / 2;
    CGFloat y = (screen.size.height - h) / 2;

    self.normalizedScanRect = CGRectMake(x / screen.size.width, y / screen.size.height,
                                         w / screen.size.width, h / screen.size.height);

    self.scanBox = [[UIView alloc] initWithFrame:CGRectMake(x, y, w, h)];
    self.scanBox.layer.borderColor = [UIColor whiteColor].CGColor;
    self.scanBox.layer.borderWidth = 3;
    self.scanBox.layer.cornerRadius = 12;
    [self.view addSubview:self.scanBox];

    self.scanLine = [[UIView alloc] initWithFrame:CGRectMake(0, 0, w, 2)];
    self.scanLine.backgroundColor = [UIColor colorWithRed:0.9 green:0.1 blue:0.1 alpha:0.8];
    [self.scanBox addSubview:self.scanLine];

    CGFloat buttonSize = 45.0;
    UIButton *cancel = [[UIButton alloc] initWithFrame:CGRectMake(20, screen.size.height-60, buttonSize, buttonSize)];
    [cancel addTarget:self action:@selector(closeView:) forControlEvents:UIControlEventTouchUpInside];
    cancel.backgroundColor = [UIColor colorWithWhite:1 alpha:0.4];
    cancel.layer.cornerRadius = buttonSize/2;
    [self.view addSubview:cancel];

    self.torchButton = [[UIButton alloc] initWithFrame:CGRectMake(screen.size.width-65, screen.size.height-60, buttonSize, buttonSize)];
    [self.torchButton addTarget:self action:@selector(toggleFlashlight:) forControlEvents:UIControlEventTouchUpInside];
    self.torchButton.backgroundColor = [UIColor colorWithWhite:1 alpha:0.4];
    self.torchButton.layer.cornerRadius = buttonSize/2;
    [self.view addSubview:self.torchButton];
}

- (void)updateCameraSelection {
    [self.session beginConfiguration];
    for (AVCaptureInput *input in self.session.inputs) [self.session removeInput:input];

    AVCaptureDevice *device = [AVCaptureDevice defaultDeviceWithMediaType:AVMediaTypeVideo];
    NSError *error;
    if ([device lockForConfiguration:&error]) {
        if ([device isFocusModeSupported:AVCaptureFocusModeContinuousAutoFocus])
            device.focusMode = AVCaptureFocusModeContinuousAutoFocus;
        if ([device isExposureModeSupported:AVCaptureExposureModeContinuousAutoExposure])
            device.exposureMode = AVCaptureExposureModeContinuousAutoExposure;
        [device unlockForConfiguration];
    }

    AVCaptureDeviceInput *input = [AVCaptureDeviceInput deviceInputWithDevice:device error:&error];
    if (input && [self.session canAddInput:input]) [self.session addInput:input];
    [self.session commitConfiguration];
}

#pragma mark - Animation / Helpers
- (UIImage *)uiImageFromCIImage:(CIImage *)ci {
    CIContext *ctx = [CIContext contextWithOptions:nil];
    CGImageRef cg = [ctx createCGImage:ci fromRect:ci.extent];
    UIImage *img = [UIImage imageWithCGImage:cg];
    CGImageRelease(cg);
    return img;
}

- (void)startScanLineAnimation {
    if (!self.scanLine) return;
    [UIView animateWithDuration:2.0 delay:0 options:UIViewAnimationOptionRepeat|UIViewAnimationOptionAutoreverse animations:^{
        self.scanLine.frame = CGRectMake(0, self.scanBox.bounds.size.height-2, self.scanBox.bounds.size.width, 2);
    } completion:nil];
}

- (void)toggleFlashlight:(id)sender {
    AVCaptureDevice *device = [AVCaptureDevice defaultDeviceWithMediaType:AVMediaTypeVideo];
    if ([device hasTorch]) {
        [device lockForConfiguration:nil];
        device.torchMode = (device.torchMode == AVCaptureTorchModeOff)
            ? AVCaptureTorchModeOn : AVCaptureTorchModeOff;
        [device unlockForConfiguration];
    }
}

- (void)closeView:(id)sender {
    [self.session stopRunning];
    [delegate closeScanner];
}
@end
