CC = clang
CFLAGS = -O2
TARGET = fda-wrapper
SRC = fda-wrapper.c

all: $(TARGET)

$(TARGET): $(SRC)
	$(CC) $(CFLAGS) -o $(TARGET) $(SRC)
	codesign -s - $(TARGET)

clean:
	rm -f $(TARGET)
