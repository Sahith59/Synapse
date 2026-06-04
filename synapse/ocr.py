import Foundation
import Quartz
import Vision
from Cocoa import NSImage

def get_active_window_image(app_name: str):
    """Finds the active window for the given app and captures a CGImage."""
    # Get all on-screen windows
    options = Quartz.kCGWindowListOptionOnScreenOnly | Quartz.kCGWindowListExcludeDesktopElements
    window_list = Quartz.CGWindowListCopyWindowInfo(options, Quartz.kCGNullWindowID)
    
    for window in window_list:
        owner = window.get(Quartz.kCGWindowOwnerName, "")
        layer = window.get(Quartz.kCGWindowLayer, -1)
        
        # We want the main window (layer 0 usually) for the target app
        if owner == app_name and layer == 0:
            window_id = window.get(Quartz.kCGWindowNumber)
            bounds = window.get(Quartz.kCGWindowBounds)
            if not window_id or not bounds:
                continue
            
            # Don't capture tiny invisible windows
            if bounds["Width"] < 100 or bounds["Height"] < 100:
                continue
            
            # Capture the exact window (excluding shadows if possible)
            image_option = Quartz.kCGWindowImageBoundsIgnoreFraming
            cg_image = Quartz.CGWindowListCreateImage(
                Quartz.CGRectNull,
                Quartz.kCGWindowListOptionIncludingWindow,
                window_id,
                image_option
            )
            return cg_image
    return None


def perform_ocr(cg_image) -> str:
    """Runs Apple Vision Framework OCR on a CGImage."""
    if not cg_image:
        return ""
    
    extracted_text = []
    
    def recognition_handler(request, error):
        if error:
            print(f"[OCR] Vision framework error: {error}")
            return
        
        observations = request.results()
        if not observations:
            return
            
        for obs in observations:
            top_candidate = obs.topCandidates_(1).firstObject()
            if top_candidate:
                extracted_text.append(top_candidate.string())

    request = Vision.VNRecognizeTextRequest.alloc().initWithCompletionHandler_(recognition_handler)
    request.setRecognitionLevel_(Vision.VNRequestTextRecognitionLevelAccurate)
    request.setUsesLanguageCorrection_(True)
    
    handler = Vision.VNImageRequestHandler.alloc().initWithCGImage_options_(cg_image, None)
    success, error = handler.performRequests_error_([request], None)
    
    if not success:
        print(f"[OCR] Failed to perform request: {error}")
        return ""
        
    return "\n".join(extracted_text)


def capture_and_ocr(app_name: str) -> str:
    """Takes a background screenshot of the app's window and OCRs the text."""
    cg_image = get_active_window_image(app_name)
    if not cg_image:
        return ""
    
    text = perform_ocr(cg_image)
    return text.strip()

if __name__ == "__main__":
    import sys
    app = sys.argv[1] if len(sys.argv) > 1 else "Terminal"
    print(f"Running OCR on active window of: {app}")
    text = capture_and_ocr(app)
    print("--- EXTRACTED TEXT ---")
    print(text)
    print("----------------------")
