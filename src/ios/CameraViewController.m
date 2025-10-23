#pragma mark - AVCaptureVideoDataOutputSampleBufferDelegate

// Add these properties at the top of your @interface if not present
// @property(nonatomic, strong) NSMutableArray<NSString *> *recentDetections;
// @property(nonatomic, assign) BOOL processingFrame;
// @property(nonatomic, assign) NSInteger requiredStableCount;
// @property(nonatomic, strong) NSDate *lastDetectionTime;

- (void)viewDidLoad {
    [super viewDidLoad];
    ...
    _recentDetections = [NSMutableArray array];
    _requiredStableCount = 7;        // must see same code 3× before accepting
    _processingFrame = NO;
}

- (void)captureOutput:(AVCaptureOutput *)captureOutput
 didOutputSampleBuffer:(CMSampleBufferRef)sampleBuffer
       fromConnection:(AVCaptureConnection *)connection {

    // prevent overlapping MLKit calls
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

    // crop to viewfinder
    CGRect screenRect = UIScreen.mainScreen.bounds;
    CGFloat imageWidth = image.size.width;
    CGFloat imageHeight = image.size.height;
    CGFloat frameSize = MIN(imageWidth, imageHeight) * _scanAreaSize;
    CGRect cropRect = CGRectMake(imageWidth/2 - frameSize/2,
                                 imageHeight/2 - frameSize/2,
                                 frameSize, frameSize);

    UIImage *croppedImg = [self croppIngimageByImageName:image toRect:cropRect];

    MLKVisionImage *visionImage = [[MLKVisionImage alloc] initWithImage:croppedImg];
    visionImage.orientation = UIImageOrientationRight;

    __weak CameraViewController *weakSelf = self;
    [self.barcodeDetector processImage:visionImage
                             completion:^(NSArray<MLKBarcode *> *barcodes, NSError *error) {
        __strong CameraViewController *self = weakSelf;
        self.processingFrame = NO;

        if (error || barcodes.count == 0) return;

        for (MLKBarcode *barcode in barcodes) {
            NSString *value = [barcode.rawValue stringByTrimmingCharactersInSet:
                               [NSCharacterSet whitespaceAndNewlineCharacterSet]];
            if (!value.length) continue;

            // add to rolling buffer
            [self.recentDetections addObject:value];
            if (self.recentDetections.count > 10)
                [self.recentDetections removeObjectAtIndex:0];

            // count how many times this value appeared recently
            NSInteger count = 0;
            for (NSString *v in self.recentDetections)
                if ([v isEqualToString:value]) count++;

            // only accept if same code appeared requiredStableCount times
            if (count >= self.requiredStableCount) {
                NSDate *now = [NSDate date];
                if (self.lastDetectionTime &&
                    [now timeIntervalSinceDate:self.lastDetectionTime] < 1.0)
                    return; // ignore duplicates within 1 s

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
