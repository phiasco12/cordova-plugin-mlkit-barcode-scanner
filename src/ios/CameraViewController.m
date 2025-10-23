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

// Added for better accuracy & patience
@property(nonatomic, strong) NSMutableArray<NSString *> *recentDetections;
@property(nonatomic, assign) BOOL processingFrame;
@property(nonatomic, assign) NSInteger requiredStableCount;
@property(nonatomic, strong) NSDate *lastDetectionTime;

@end

@implementation CameraViewController
@synthesize delegate;

- (BOOL)prefersStatusBarHidden { return YES; }
- (BOOL)prefersHomeIndicatorAutoHidden { return YES; }
- (BOOL)shouldAutorotate { return NO; }
- (UIInterfaceOrientationMask)supportedInterfaceOrientations { return UIInterfaceOrientationMaskPortrait; }

- (id)initWithCoder:(NSCoder *)aDecoder {
    self = [super initWithCoder:aDecoder];
    if (self) {
        _videoDataOutputQueue = dispatch_queue_create("VideoDataOutputQueue", DISPATCH_QUEUE_SERIAL);
    }
    return self;
}

- (void)viewDidLoad {
    [super viewDidLoad];

    self.session = [[AVCaptureSession alloc] init];
    self.session.sessionPreset = AVCaptureSessionPresetHigh;
    _videoDataOutputQueue = dispatch_queue_create("VideoDataOutputQueue", DISPATCH_QUEUE_SERIAL);
    [self updateCameraSelection];
    [self setUpVideoProcessing];
    [self setUpCameraPreview];

    NSNumber *formats = 0;
    if([_barcodeFormats isEqual:@0]) {
        formats = @(MLKBarcodeFormatCode39 | MLKBarcodeFormatDataMatrix);
    } else {
        formats = _barcodeFormats;
    }

    MLKBarcodeScannerOptions *options = [[MLKBarcodeScannerOptions alloc] initWithFormats:[formats intValue]];
    self.barcodeDetector = [MLKBarcodeScanner barcodeScannerWithOptions:options];

    // ✅ Initialize detection stability
    _recentDetections = [NSMutableArray array];
    _requiredStableCount = 3;
    _processingFrame = NO;
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
}

- (void)viewDidDisappear:(BOOL)animated {
    [super viewDidDisappear:animated];
    [self.session stopRunning];
}

#pragma mark - Frame Processing

- (void)captureOutput:(AVCaptureOutput *)captureOutput
 didOutputSampleBuffer:(CMSampleBufferRef)sampleBuffer
       fromConnection:(AVCaptureConnection *)connection {

    if (self.processingFrame) return;
    self.processingFrame = YES;

    CVImageBufferRef imageBuffer = CMSampleBufferGetImageBuffer(sampleBuffer);
    CIImage *ciImage = [CIImage imageWithCVPixelBuffer:imageBuffer];
    CIContext *temporaryContext = [CIContext contextWithOptions:nil];
    CGImageRef videoImage = [temporaryContext
                             createCGImage:ciImage
                             fromRect:CGRectMake(0, 0,
                                                 CVPixelBufferGetWidth(imageBuffer),
                                                 CVPixelBufferGetHeight(imageBuffer))];
    UIImage *image = [[UIImage alloc] initWithCGImage:videoImage];
    CGImageRelease(videoImage);

    CGFloat imageWidth = image.size.width;
    CGFloat imageHeight = image.size.height;
    CGFloat frameSize = MIN(imageWidth, imageHeight) * _scanAreaSize;
    CGRect cropRect = CGRectMake(imageWidth/2 - frameSize/2,
                                 imageHeight/2 - frameSize/2,
                                 frameSize, frameSize);
    UIImage *croppedImg = [self croppIngimageByImageName:image toRect:cropRect];

    MLKVisionImage *visionImage = [[MLKVisionImage alloc] initWithImage:croppedImg];
    visionImage.orientation = UIImageOrientationRight;

    __weak typeof(self) weakSelf = self;
    [self.barcodeDetector processImage:visionImage
                             completion:^(NSArray<MLKBarcode *> *barcodes, NSError *error) {
        __strong typeof(self) self = weakSelf;
        self.processingFrame = NO;

        if (error || barcodes.count == 0) return;

        for (MLKBarcode *barcode in barcodes) {
            NSString *value = [barcode.rawValue stringByTrimmingCharactersInSet:
                               [NSCharacterSet whitespaceAndNewlineCharacterSet]];
            if (!value.length) continue;

            [self.recentDetections addObject:value];
            if (self.recentDetections.count > 10)
                [self.recentDetections removeObjectAtIndex:0];

            NSInteger count = 0;
            for (NSString *v in self.recentDetections)
                if ([v isEqualToString:value]) count++;

            if (count >= self.requiredStableCount) {
                NSDate *now = [NSDate date];
                if (self.lastDetectionTime &&
                    [now timeIntervalSinceDate:self.lastDetectionTime] < 1.0)
                    return;
                self.lastDetectionTime = now;

                dispatch_async(dispatch_get_main_queue(), ^{
                    [self cleanupCaptureSession];
                    [self->_session stopRunning];
                    [self->delegate sendResult:barcode];
                });
                return;
            }
        }
    }];
}

#pragma mark - Camera setup

- (void)cleanupVideoProcessing {
    if (self.videoDataOutput) [self.session removeOutput:self.videoDataOutput];
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
    NSDictionary *rgbOutputSettings = @{
        (__bridge NSString*)kCVPixelBufferPixelFormatTypeKey : @(kCVPixelFormatType_32BGRA)
    };
    [self.videoDataOutput setVideoSettings:rgbOutputSettings];
    [self.videoDataOutput setAlwaysDiscardsLateVideoFrames:YES];
    [self.videoDataOutput setSampleBufferDelegate:self queue:self.videoDataOutputQueue];
    if ([self.session canAddOutput:self.videoDataOutput]) {
        [self.session addOutput:self.videoDataOutput];
    }
}

- (void)setUpCameraPreview {
    self.previewLayer = [[AVCaptureVideoPreviewLayer alloc] initWithSession:self.session];
    [self.previewLayer setBackgroundColor:[UIColor blackColor].CGColor];
    [self.previewLayer setVideoGravity:AVLayerVideoGravityResizeAspectFill];
    self.previewLayer.frame = self.view.superview.bounds;
    [self.view.layer addSublayer:self.previewLayer];
}

#pragma mark - Helpers

- (UIImage *)croppIngimageByImageName:(UIImage *)imageToCrop toRect:(CGRect)rect {
    CGImageRef imageRef = CGImageCreateWithImageInRect([imageToCrop CGImage], rect);
    UIImage *cropped = [UIImage imageWithCGImage:imageRef];
    CGImageRelease(imageRef);
    return cropped;
}

- (void)toggleFlashlight:(id)sender {
    AVCaptureDevice *device = [AVCaptureDevice defaultDeviceWithMediaType:AVMediaTypeVideo];
    if ([device hasTorch] && [device hasFlash]) {
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

- (void)closeView:(id)sender {
    [self cleanupCaptureSession];
    [_session stopRunning];
    [delegate closeScanner];
}

- (void)updateCameraSelection {
    [self.session beginConfiguration];
    NSArray *oldInputs = [self.session inputs];
    for (AVCaptureInput *oldInput in oldInputs) [self.session removeInput:oldInput];
    AVCaptureDevice *device = [AVCaptureDevice defaultDeviceWithMediaType:AVMediaTypeVideo];
    NSError *error;
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
    if (input && [self.session canAddInput:input]) [self.session addInput:input];
    [self.session commitConfiguration];
}

@end
