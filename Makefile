SDK := $(shell xcrun --sdk iphoneos --show-sdk-path)
CC  := clang

CFLAGS  := -arch arm64 -isysroot $(SDK) -miphoneos-version-min=11.0 -fobjc-arc -ObjC
LDFLAGS := -dynamiclib -framework Foundation -framework UIKit -framework WebKit -framework AVFoundation

OUT := AliSniffer.dylib
SRC := AliSniffer.m

all: $(OUT)

$(OUT): $(SRC)
	$(CC) $(CFLAGS) $(SRC) $(LDFLAGS) -o $(OUT)

clean:
	rm -f $(OUT)
