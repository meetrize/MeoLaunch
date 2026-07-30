#import "MLLaunchAtLogin.h"

#import <ServiceManagement/ServiceManagement.h>

@implementation MLLaunchAtLogin

+ (SMAppService *)mainService {
    return SMAppService.mainAppService;
}

+ (BOOL)isBenignError:(NSError *)error {
    if (!error) {
        return YES;
    }
    /* Framework domain uses kSMError* codes from SMErrors.h */
    if (error.code == kSMErrorAlreadyRegistered || error.code == kSMErrorJobNotFound) {
        return YES;
    }
    return NO;
}

+ (BOOL)isEnabled {
    SMAppServiceStatus status = [self mainService].status;
    return status == SMAppServiceStatusEnabled ||
           status == SMAppServiceStatusRequiresApproval;
}

+ (void)openLoginItemsSettings {
    [SMAppService openSystemSettingsLoginItems];
}

+ (BOOL)setEnabled:(BOOL)enabled error:(NSError **)error {
    SMAppService *svc = [self mainService];
    SMAppServiceStatus status = svc.status;

    if (enabled) {
        if (status == SMAppServiceStatusEnabled) {
            return YES;
        }
        if (status == SMAppServiceStatusRequiresApproval) {
            [self openLoginItemsSettings];
            return YES;
        }
        NSError *regErr = nil;
        BOOL ok = [svc registerAndReturnError:&regErr];
        if (!ok && ![self isBenignError:regErr]) {
            if (error) {
                *error = regErr;
            }
            NSLog(@"[MeoLaunch] launch-at-login register failed: %@", regErr);
            if (svc.status == SMAppServiceStatusRequiresApproval ||
                (regErr && regErr.code == kSMErrorLaunchDeniedByUser)) {
                [self openLoginItemsSettings];
            }
            return NO;
        }
        if (svc.status == SMAppServiceStatusRequiresApproval) {
            [self openLoginItemsSettings];
        }
        return YES;
    }

    if (status == SMAppServiceStatusNotRegistered ||
        status == SMAppServiceStatusNotFound) {
        return YES;
    }
    NSError *unregErr = nil;
    BOOL ok = [svc unregisterAndReturnError:&unregErr];
    if (!ok && ![self isBenignError:unregErr]) {
        if (error) {
            *error = unregErr;
        }
        NSLog(@"[MeoLaunch] launch-at-login unregister failed: %@", unregErr);
        return NO;
    }
    return YES;
}

@end
