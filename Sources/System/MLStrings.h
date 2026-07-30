#import <Foundation/Foundation.h>

typedef NS_ENUM(NSInteger, MLLanguage) {
    MLLanguageEnglish = 0,
    MLLanguageChinese = 1,
};

FOUNDATION_EXPORT NSNotificationName const MLLanguageDidChangeNotification;

@interface MLStrings : NSObject

+ (MLLanguage)language;
+ (void)setLanguage:(MLLanguage)language;
+ (MLLanguage)languageFromCode:(NSString *)code;
+ (NSString *)codeForLanguage:(MLLanguage)language;
+ (MLLanguage)systemPreferredLanguage;

/** Localized string for key; falls back to English then the key itself. */
+ (NSString *)t:(NSString *)key;

@end
