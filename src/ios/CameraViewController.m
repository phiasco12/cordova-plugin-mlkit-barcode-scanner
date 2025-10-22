@import AVFoundation;
@import MLKitBarcodeScanning;
@import MLKitVision;

#import "CameraViewController.h"

@interface CameraViewController ()<AVCaptureVideoDataOutputSampleBufferDelegate>

@property(nonatomic, weak) IBOutlet UIView *placeHolderView;
@property(nonatomic, weak) IBOutlet UIView *overlayView;
@property(nonatomic, strong) UIImageView *imageView;

@property(nonatomic, strong) AVCaptureSession *session;
@property(nonatomic, strong) AVCaptureVideoDataOutput *videoDataOutput;
@property(nonatomic, strong) dispatch_queue_t videoDataOutputQueue;
@property(nonatomic, strong) AVCaptureVideoPreviewLayer *previewLayer;

@property(nonatomic, strong) MLKBarcodeScanner *barcodeDetector;
@property(nonatomic, strong) UIButton *torchButton;

// ✅ Stability buffer
@property(nonatomic, strong) NSMutableArray<NSString *> *recentDetections;
@property(nonatomic, assign) NSInteger requiredStableCount;

@property(nonatomic, strong) UIView *scanBox;
@property(nonatomic, strong) UIView *scanLine;

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
        _requiredStableCount = 3; // ✅ require same value 3 times
    }
    return self;
}

- (void)viewDidLoad {
    [super viewDidLoad];

    // ✅ Use high resolution
    self.session = [[AVCaptureSession alloc] init];
    self.session.sessionPreset = AVCaptureSessionPreset1920x1080;

    _videoDataOutputQueue = dispatch_queue_create("VideoDataOutputQueue", DISPATCH_QUEUE_SERIAL);

    [self updateCameraSelection];
    [self setUpVideoProcessing];
    [self setUpCameraPreview];

    // Parse Cordova settings.
    NSNumber *formats = 0;
    if([_barcodeFormats  isEqual: @0]) {
        formats = @(MLKBarcodeFormatCode39|MLKBarcodeFormatDataMatrix);
    } else if([_barcodeFormats  isEqual: @1234]) {
    } else {
        formats = _barcodeFormats;
    }
    MLKBarcodeScannerOptions *options = [[MLKBarcodeScannerOptions alloc] initWithFormats: [formats intValue]];
    self.barcodeDetector = [MLKBarcodeScanner barcodeScannerWithOptions:options];
}

- (void)viewDidLayoutSubviews {
    [super viewDidLayoutSubviews];
    self.previewLayer.frame = self.view.layer.bounds;
    self.previewLayer.position = CGPointMake(CGRectGetMidX(self.previewLayer.frame),
                                             CGRectGetMidY(self.previewLayer.frame));
}

- (void)viewDidAppear:(BOOL)animated {
    [super viewDidAppear:animated];
    [[UIDevice currentDevice] setValue:@(UIInterfaceOrientationPortrait) forKey:@"orientation"];
    [self.session startRunning];

    // ✅ Start scan line animation
    [self startScanLineAnimation];
}

- (void)viewDidDisappear:(BOOL)animated {
    [super viewDidDisappear:animated];
    [self.session stopRunning];
}

#pragma mark - AVCaptureVideoDataOutputSampleBufferDelegate

- (void)captureOutput:(AVCaptureOutput *)captureOutput
didOutputSampleBuffer:(CMSampleBufferRef)sampleBuffer
       fromConnection:(AVCaptureConnection *)connection {

    CVImageBufferRef imageBuffer = CMSampleBufferGetImageBuffer(sampleBuffer);
    CIImage *ciImage = [CIImage imageWithCVPixelBuffer:imageBuffer];
    CIContext *temporaryContext = [CIContext contextWithOptions:nil];
    CGImageRef videoImage = [temporaryContext createCGImage:ciImage
                                                   fromRect:CGRectMake(0, 0,
                                                                       CVPixelBufferGetWidth(imageBuffer),
                                                                       CVPixelBufferGetHeight(imageBuffer))];

    UIImage *image = [[UIImage alloc] initWithCGImage:videoImage];
    CGImageRelease(videoImage);

    UIImage *croppedImg = nil;

    CGRect screenRect = [[UIScreen mainScreen] bounds];
    CGFloat screenWidth = screenRect.size.width;
    CGFloat screenHeight = screenRect.size.height;

    CGFloat imageWidth = image.size.width;
    CGFloat imageHeight = image.size.height;

    CGFloat actualFrameWidth = 0;
    CGFloat actualFrameHeight = 0;

    if(imageWidth/screenWidth < imageHeight/screenHeight){
        actualFrameWidth = imageWidth * _scanAreaSize;
        actualFrameHeight = actualFrameWidth;
    } else {
        actualFrameHeight = imageHeight * _scanAreaSize;
        actualFrameWidth = actualFrameHeight;
    }

    CGRect cropRect = CGRectMake(imageWidth/2 - actualFrameWidth/2,
                                 imageHeight/2 - actualFrameHeight/2,
                                 actualFrameWidth, actualFrameHeight);

    croppedImg = [self croppIngimageByImageName:image toRect:cropRect];

    // ✅ Pass correct orientation
    MLKVisionImage *portraitImage = [[MLKVisionImage alloc] initWithImage:croppedImg];
    portraitImage.orientation = UIImageOrientationRight;

    [self.barcodeDetector processImage:portraitImage completion:^(NSArray<MLKBarcode *> *barcodes, NSError *error) {
        if (error != nil) { return; }
        if (barcodes != nil) {
            for (MLKBarcode *barcode in barcodes) {
                NSString *value = barcode.rawValue;
                if (!value) continue;

                // ✅ Stability filter
                [self.recentDetections addObject:value];
                if (self.recentDetections.count > self.requiredStableCount) {
                    [self.recentDetections removeObjectAtIndex:0];
                }

                NSInteger count = 0;
                for (NSString *v in self.recentDetections) {
                    if ([v isEqualToString:value]) count++;
                }

                if (count >= self.requiredStableCount) {
                    [self cleanupCaptureSession];
                    [self->_session stopRunning];
                    [self->delegate sendResult:barcode];
                    break;
                }
            }
        }
    }];
}

#pragma mark - Camera setup

- (void)cleanupVideoProcessing {
    if (self.videoDataOutput) {
        [self.session removeOutput:self.videoDataOutput];
    }
    self.videoDataOutput = nil;
}

- (void)cleanupCaptureSession {
    [self.session stopRunning];
    [self cleanupVideoProcessing];
    self.session = nil;
    [self.previewLayer removeFromSuperlayer];
}

- (void)setUpVideoProcessing {
    self.videoDataOutput = [[AVCaptureVideoDataOutput alloc] init];
    NSDictionary *rgbOutputSettings = @{(__bridge NSString*)kCVPixelBufferPixelFormatTypeKey : @(kCVPixelFormatType_32BGRA)};
    [self.videoDataOutput setVideoSettings:rgbOutputSettings];

    if (![self.session canAddOutput:self.videoDataOutput]) {
        [self cleanupVideoProcessing];
        return;
    }
    [self.videoDataOutput setAlwaysDiscardsLateVideoFrames:YES];
    [self.videoDataOutput setSampleBufferDelegate:self queue:self.videoDataOutputQueue];
    [self.session addOutput:self.videoDataOutput];
}

- (void)setUpCameraPreview {
    self.previewLayer = [[AVCaptureVideoPreviewLayer alloc] initWithSession:self.session];
    [self.previewLayer setBackgroundColor:[UIColor blackColor].CGColor];
    [self.previewLayer setVideoGravity:AVLayerVideoGravityResizeAspectFill];
    self.previewLayer.frame = self.view.superview.bounds;
    [self.view.layer addSublayer:self.previewLayer];

    CGRect screenRect = [[UIScreen mainScreen] bounds];
    CGFloat screenWidth = screenRect.size.width;
    CGFloat screenHeight = screenRect.size.height;

    CGFloat frameWidth = screenWidth*_scanAreaSize;
    CGFloat frameHeight = frameWidth;

    // ✅ Animated scan box
    self.scanBox = [[UIView alloc] initWithFrame:CGRectMake(screenWidth/2 - frameWidth/2,
                                                            screenHeight/2 - frameHeight/2,
                                                            frameWidth, frameHeight)];
    self.scanBox.layer.borderColor = [UIColor whiteColor].CGColor;
    self.scanBox.layer.borderWidth = 3.0;
    self.scanBox.layer.cornerRadius = 12.0;
    [self.view addSubview:self.scanBox];

    // ✅ Scan line
    self.scanLine = [[UIView alloc] initWithFrame:CGRectMake(0, 0, frameWidth, 2)];
    self.scanLine.backgroundColor = [UIColor colorWithRed:0.9 green:0.1 blue:0.1 alpha:0.8];
    [self.scanBox addSubview:self.scanLine];

    // Cancel + Torch buttons (kept from your original code)
    CGFloat buttonSize = 45.0;
    UIButton *_cancelButton = [[UIButton alloc] init];
    [_cancelButton addTarget:self action:@selector(closeView:) forControlEvents:UIControlEventTouchUpInside];
    _cancelButton.frame = CGRectMake(20, screenHeight-60, buttonSize, buttonSize);
    _cancelButton.backgroundColor = [UIColor colorWithWhite:1 alpha:0.4];
    _cancelButton.layer.cornerRadius = buttonSize/2;
    [self.view addSubview:_cancelButton];

    self.torchButton = [[UIButton alloc] init];
    [self.torchButton addTarget:self action:@selector(toggleFlashlight:) forControlEvents:UIControlEventTouchUpInside];
    self.torchButton.frame = CGRectMake(screenWidth-65, screenHeight-60, buttonSize, buttonSize);
    self.torchButton.backgroundColor = [UIColor colorWithWhite:1 alpha:0.4];
    self.torchButton.layer.cornerRadius = buttonSize/2;
    [self.view addSubview:self.torchButton];
}

#pragma mark - Scan line animation
- (void)startScanLineAnimation {
    if (!self.scanLine) return;
    [UIView animateWithDuration:2.0 delay:0 options:UIViewAnimationOptionRepeat | UIViewAnimationOptionAutoreverse animations:^{
        self.scanLine.frame = CGRectMake(0, self.scanBox.bounds.size.height-2,
                                         self.scanBox.bounds.size.width, 2);
    } completion:nil];
}

#pragma mark - Helpers
- (UIImage *)croppIngimageByImageName:(UIImage *)imageToCrop toRect:(CGRect)rect {
    CGImageRef imageRef = CGImageCreateWithImageInRect([imageToCrop CGImage], rect);
    UIImage *cropped = [UIImage imageWithCGImage:imageRef];
    CGImageRelease(imageRef);
    return cropped;
}

- (void) toggleFlashlight:(id)sender {
    AVCaptureDevice *device = [AVCaptureDevice defaultDeviceWithMediaType:AVMediaTypeVideo];
    if ([device hasTorch] && [device hasFlash]){
        [device lockForConfiguration:nil];
        if (device.torchMode == AVCaptureTorchModeOff) {
            [device setTorchMode:AVCaptureTorchModeOn];
            [device setFlashMode:AVCaptureFlashModeOn];
        } else {
            [device setTorchMode:AVCaptureTorchModeOff];
            [device setFlashMode:AVCaptureFlashModeOff];
        }
        [device unlockForConfiguration];
    }
}

- (void) closeView :(id)sender {
    [ self cleanupCaptureSession];
    [_session stopRunning];
    [delegate closeScanner];
}

- (void)updateCameraSelection {
    [self.session beginConfiguration];
    NSArray *oldInputs = [self.session inputs];
    for (AVCaptureInput *oldInput in oldInputs) {
        [self.session removeInput:oldInput];
    }
    AVCaptureDevice *device = [AVCaptureDevice defaultDeviceWithMediaType:AVMediaTypeVideo];
    NSError *error;
    if ([device lockForConfiguration:&error]) {
        if ([device isFocusModeSupported:AVCaptureFocusModeContinuousAutoFocus]) {
            device.focusMode = AVCaptureFocusModeContinuousAutoFocus; // ✅ continuous focus
        }
        if ([device isExposureModeSupported:AVCaptureExposureModeContinuousAutoExposure]) {
            device.exposureMode = AVCaptureExposureModeContinuousAutoExposure; // ✅ continuous exposure
        }
        [device unlockForConfiguration];
    }
    AVCaptureDeviceInput *input = [AVCaptureDeviceInput deviceInputWithDevice:device error:&error];
    if (input && [self.session canAddInput:input]) {
        [self.session addInput:input];
    }
    [self.session commitConfiguration];
}

@end
