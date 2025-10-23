@import AVFoundation;
@import MLKitBarcodeScanning;
@import MLKitVision;

#import "CameraViewController.h"

@interface CameraViewController () <AVCaptureVideoDataOutputSampleBufferDelegate>

// UI
@property (nonatomic, strong) AVCaptureVideoPreviewLayer *previewLayer;
@property (nonatomic, strong) UIView *scanBox;
@property (nonatomic, strong) UIView *scanLine;
@property (nonatomic, strong) UIButton *torchButton;

// Camera
@property (nonatomic, strong) AVCaptureSession *session;
@property (nonatomic, strong) AVCaptureVideoDataOutput *videoDataOutput;
@property (nonatomic, strong) dispatch_queue_t videoDataOutputQueue;

// ML Kit
@property (nonatomic, strong) MLKBarcodeScanner *barcodeDetector;

// Stability / state
@property (nonatomic, strong) NSMutableArray<NSString *> *recentDetections;
@property (nonatomic, assign) NSInteger requiredStableCount;
@property (nonatomic, assign) BOOL processingFrame;

// ROI (visual only; we filter detections to the box afterward)
@property (nonatomic, assign) CGRect normalizedScanRect;

@end

@implementation CameraViewController
@synthesize delegate;

#pragma mark - View / Orientation

- (BOOL)prefersStatusBarHidden { return YES; }
- (BOOL)prefersHomeIndicatorAutoHidden { return YES; }
- (BOOL)shouldAutorotate { return NO; }
- (UIInterfaceOrientationMask)supportedInterfaceOrientations { return UIInterfaceOrientationMaskPortrait; }

- (instancetype)initWithCoder:(NSCoder *)aDecoder {
    if ((self = [super initWithCoder:aDecoder])) {
        _videoDataOutputQueue = dispatch_queue_create("VideoDataOutputQueue", DISPATCH_QUEUE_SERIAL);
        _recentDetections = [NSMutableArray array];
        _requiredStableCount = 3;
        _processingFrame = NO;
    }
    return self;
}

- (void)viewDidLoad {
    [super viewDidLoad];

    // Session
    self.session = [[AVCaptureSession alloc] init];
    // High resolution; stable on modern devices
    self.session.sessionPreset = AVCaptureSessionPreset1920x1080;

    [self updateCameraSelection];
    [self setUpVideoProcessing];
    [self setUpCameraPreview];

    // MLKit options
    NSNumber *formats = 0;
    if ([_barcodeFormats isEqual:@0]) {
        // Your legacy VIN-style example
        formats = @(MLKBarcodeFormatCode39 | MLKBarcodeFormatDataMatrix);
    } else {
        formats = _barcodeFormats ?: @(MLKBarcodeFormatAll);
    }
    MLKBarcodeScannerOptions *options = [[MLKBarcodeScannerOptions alloc] initWithFormats:[formats intValue]];
    self.barcodeDetector = [MLKBarcodeScanner barcodeScannerWithOptions:options];
}

- (void)viewDidAppear:(BOOL)animated {
    [super viewDidAppear:animated];
    // Force portrait view; (note: this is common in scanner apps)
    [[UIDevice currentDevice] setValue:@(UIInterfaceOrientationPortrait) forKey:@"orientation"];
    [self.session startRunning];
    [self startScanLineAnimation];
}

- (void)viewDidDisappear:(BOOL)animated {
    [super viewDidDisappear:animated];
    [self.session stopRunning];
}

#pragma mark - Capture delegate

- (void)captureOutput:(AVCaptureOutput *)output
didOutputSampleBuffer:(CMSampleBufferRef)sampleBuffer
       fromConnection:(AVCaptureConnection *)connection {

    // Avoid overlapping detections
    if (self.processingFrame) return;
    self.processingFrame = YES;

    // Build MLKit VisionImage directly from buffer (fast + correct metadata)
    MLKVisionImage *visionImage = [[MLKVisionImage alloc] initWithBuffer:sampleBuffer];
    visionImage.orientation = [self imageOrientationForDevice];

    // Process
    __weak typeof(self) weakSelf = self;
    [self.barcodeDetector processImage:visionImage completion:^(NSArray<MLKBarcode *> * _Nullable barcodes, NSError * _Nullable error) {
        __strong typeof(self) self = weakSelf;
        self.processingFrame = NO;
        if (error || barcodes.count == 0) return;

        // Compute ROI in image coords to only accept barcodes inside the visible box.
        // We avoid cropping buffers (which caused crashes). Instead we filter results.
        CGSize imageSize = [self imageSizeForSampleBuffer:sampleBuffer orientation:visionImage.orientation];
        CGRect roiImageRect = [self roiImageSpaceFromNormalized:self.normalizedScanRect imageSize:imageSize];

        for (MLKBarcode *barcode in barcodes) {
            if (CGRectIsEmpty(barcode.frame)) continue;

            // Only accept if the barcode's center lies inside the ROI derived from the box
            CGPoint center = CGPointMake(CGRectGetMidX(barcode.frame), CGRectGetMidY(barcode.frame));
            if (!CGRectContainsPoint(roiImageRect, center)) {
                continue;
            }

            NSString *value = [barcode.rawValue stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
            if (!value.length) continue;

            // Normalize + regex filter (adjust the pattern if needed)
            value = value.uppercaseString;
            NSRegularExpression *regex = [NSRegularExpression regularExpressionWithPattern:@"^RF[0-9]{5,6}$" options:0 error:nil];
            if ([regex numberOfMatchesInString:value options:0 range:NSMakeRange(0, value.length)] == 0) {
                continue;
            }

            // Stability (majority vote over recent frames)
            [self.recentDetections addObject:value];
            if (self.recentDetections.count > 10) {
                [self.recentDetections removeObjectAtIndex:0];
            }

            NSMutableDictionary<NSString *, NSNumber *> *freq = [NSMutableDictionary dictionary];
            for (NSString *v in self.recentDetections) {
                freq[v] = @([freq[v] intValue] + 1);
            }

            __block NSString *best = nil;
            __block NSInteger maxCount = 0;
            [freq enumerateKeysAndObjectsUsingBlock:^(NSString *key, NSNumber *obj, BOOL *stop) {
                NSInteger c = obj.integerValue;
                if (c > maxCount) { maxCount = c; best = key; }
            }];

            if (maxCount >= self.requiredStableCount && [value isEqualToString:best]) {
                dispatch_async(dispatch_get_main_queue(), ^{
                    if (self.session.isRunning) {
                        [self.session stopRunning];
                    }
                    [self->delegate sendResult:barcode];
                });
                return;
            }
        }
    }];
}

#pragma mark - Image / ROI helpers

// Map device orientation to UIImageOrientation for ML Kit
- (UIImageOrientation)imageOrientationForDevice {
    UIDeviceOrientation d = UIDevice.currentDevice.orientation;
    // Default to portrait if unknown/faceUp/etc.
    switch (d) {
        case UIDeviceOrientationLandscapeLeft:  return UIImageOrientationUp;
        case UIDeviceOrientationLandscapeRight: return UIImageOrientationDown;
        case UIDeviceOrientationPortraitUpsideDown: return UIImageOrientationLeft;
        case UIDeviceOrientationPortrait:
        default: return UIImageOrientationRight;
    }
}

// Compute the image size that MLKit uses AFTER applying orientation.
// We need this to translate the on-screen ROI to MLKit image coordinates.
- (CGSize)imageSizeForSampleBuffer:(CMSampleBufferRef)sampleBuffer orientation:(UIImageOrientation)orientation {
    CVImageBufferRef buf = CMSampleBufferGetImageBuffer(sampleBuffer);
    size_t w = CVPixelBufferGetWidth(buf);
    size_t h = CVPixelBufferGetHeight(buf);
    BOOL portraitLike = (orientation == UIImageOrientationRight || orientation == UIImageOrientationLeft);
    return portraitLike ? CGSizeMake(h, w) : CGSizeMake(w, h);
}

// Convert normalized on-screen ROI into MLKit image coordinates.
- (CGRect)roiImageSpaceFromNormalized:(CGRect)norm imageSize:(CGSize)imgSize {
    // norm is 0..1 based (x,y,w,h) in screen space proportions.
    // After orientation is applied, MLKit gives barcode.frame in this "image space".
    CGFloat x = norm.origin.x * imgSize.width;
    CGFloat y = norm.origin.y * imgSize.height;
    CGFloat w = norm.size.width * imgSize.width;
    CGFloat h = norm.size.height * imgSize.height;
    return CGRectMake(x, y, w, h);
}

#pragma mark - Camera setup

- (void)setUpVideoProcessing {
    self.videoDataOutput = [[AVCaptureVideoDataOutput alloc] init];
    NSDictionary *settings = @{ (__bridge NSString*)kCVPixelBufferPixelFormatTypeKey : @(kCVPixelFormatType_32BGRA) };
    self.videoDataOutput.videoSettings = settings;
    self.videoDataOutput.alwaysDiscardsLateVideoFrames = YES;
    [self.videoDataOutput setSampleBufferDelegate:self queue:self.videoDataOutputQueue];

    if ([self.session canAddOutput:self.videoDataOutput]) {
        [self.session addOutput:self.videoDataOutput];
    }

    // Force portrait orientation on the video connection when available
    AVCaptureConnection *conn = [self.videoDataOutput connectionWithMediaType:AVMediaTypeVideo];
    if (conn && [conn isVideoOrientationSupported]) {
        conn.videoOrientation = AVCaptureVideoOrientationPortrait;
    }
}

- (void)setUpCameraPreview {
    self.previewLayer = [[AVCaptureVideoPreviewLayer alloc] initWithSession:self.session];
    self.previewLayer.videoGravity = AVLayerVideoGravityResizeAspectFill;
    self.previewLayer.frame = self.view.bounds;               // <— safe; view is ready
    [self.view.layer addSublayer:self.previewLayer];

    // Build overlay based on _scanAreaSize (fallback 0.7 if not provided)
    CGFloat scanFrac = (_scanAreaSize > 0.0 && _scanAreaSize <= 1.0) ? _scanAreaSize : 0.7;

    CGRect screen = UIScreen.mainScreen.bounds;
    CGFloat w = screen.size.width * scanFrac;
    CGFloat h = w; // square
    CGFloat x = (screen.size.width - w) / 2.0;
    CGFloat y = (screen.size.height - h) / 2.0;

    // Normalized ROI (0..1) used to filter detections in image space
    self.normalizedScanRect = CGRectMake(x / screen.size.width,
                                         y / screen.size.height,
                                         w / screen.size.width,
                                         h / screen.size.height);

    // White box
    self.scanBox = [[UIView alloc] initWithFrame:CGRectMake(x, y, w, h)];
    self.scanBox.layer.borderColor = [UIColor whiteColor].CGColor;
    self.scanBox.layer.borderWidth = 3.0;
    self.scanBox.layer.cornerRadius = 12.0;
    [self.view addSubview:self.scanBox];

    // Red scanning line
    self.scanLine = [[UIView alloc] initWithFrame:CGRectMake(0, 0, w, 2)];
    self.scanLine.backgroundColor = [UIColor colorWithRed:0.9 green:0.1 blue:0.1 alpha:0.9];
    [self.scanBox addSubview:self.scanLine];

    // Cancel + Torch (simple visuals — you can swap in your base64 icons if you like)
    CGFloat buttonSize = 45.0;
    UIButton *cancel = [[UIButton alloc] initWithFrame:CGRectMake(20, screen.size.height - 60, buttonSize, buttonSize)];
    cancel.backgroundColor = [UIColor colorWithWhite:1 alpha:0.4];
    cancel.layer.cornerRadius = buttonSize/2;
    [cancel addTarget:self action:@selector(closeView:) forControlEvents:UIControlEventTouchUpInside];
    [self.view addSubview:cancel];

    self.torchButton = [[UIButton alloc] initWithFrame:CGRectMake(screen.size.width - 65, screen.size.height - 60, buttonSize, buttonSize)];
    self.torchButton.backgroundColor = [UIColor colorWithWhite:1 alpha:0.4];
    self.torchButton.layer.cornerRadius = buttonSize/2;
    [self.torchButton addTarget:self action:@selector(toggleFlashlight:) forControlEvents:UIControlEventTouchUpInside];
    [self.view addSubview:self.torchButton];
}

- (void)updateCameraSelection {
    [self.session beginConfiguration];

    // Remove previous inputs
    for (AVCaptureInput *old in self.session.inputs) {
        [self.session removeInput:old];
    }

    AVCaptureDevice *device = [AVCaptureDevice defaultDeviceWithMediaType:AVMediaTypeVideo];
    NSError *error = nil;
    if ([device lockForConfiguration:&error]) {
        if ([device isFocusModeSupported:AVCaptureFocusModeContinuousAutoFocus]) {
            device.focusMode = AVCaptureFocusModeContinuousAutoFocus;
        }
        if ([device isExposureModeSupported:AVCaptureExposureModeContinuousAutoExposure]) {
            device.exposureMode = AVCaptureExposureModeContinuousAutoExposure;
        }
        [device unlockForConfiguration];
    }

    AVCaptureDeviceInput *input = [AVCaptureDeviceInput deviceInputWithDevice:device error:&error];
    if (input && [self.session canAddInput:input]) {
        [self.session addInput:input];
    }

    [self.session commitConfiguration];
}

#pragma mark - UI helpers

- (void)startScanLineAnimation {
    if (!self.scanLine) return;
    [UIView animateWithDuration:1.8
                          delay:0
                        options:UIViewAnimationOptionRepeat | UIViewAnimationOptionAutoreverse
                     animations:^{
        self.scanLine.frame = CGRectMake(0,
                                         self.scanBox.bounds.size.height - 2.0,
                                         self.scanBox.bounds.size.width,
                                         2.0);
    } completion:nil];
}

- (void)toggleFlashlight:(id)sender {
    AVCaptureDevice *device = [AVCaptureDevice defaultDeviceWithMediaType:AVMediaTypeVideo];
    if (![device hasTorch]) return;
    NSError *err = nil;
    if (![device lockForConfiguration:&err]) return;
    device.torchMode = (device.torchMode == AVCaptureTorchModeOn) ? AVCaptureTorchModeOff : AVCaptureTorchModeOn;
    [device unlockForConfiguration];
}

- (void)closeView:(id)sender {
    if (self.session.isRunning) {
        [self.session stopRunning];
    }
    [delegate closeScanner];
}

@end
