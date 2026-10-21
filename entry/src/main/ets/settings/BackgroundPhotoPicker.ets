import dataSharePredicates from '@ohos.data.dataSharePredicates';
import photoAccessHelper from '@ohos.file.photoAccessHelper';
import image from '@ohos.multimedia.image';
import common from '@ohos.app.ability.common';

export interface SelectedBackgroundPhoto {
  uri: string;
  thumbnail: image.PixelMap;
}

export class BackgroundPhotoPicker {
  async pick(context: common.UIAbilityContext): Promise<SelectedBackgroundPhoto | undefined> {
    const picker = new photoAccessHelper.PhotoViewPicker();
    const options = new photoAccessHelper.PhotoSelectOptions();
    options.MIMEType = photoAccessHelper.PhotoViewMIMETypes.IMAGE_TYPE;
    options.maxSelectNumber = 1;

    let selected: photoAccessHelper.PhotoSelectResult;
    try {
      selected = await picker.select(options);
    } catch (error) {
      const message = error instanceof Error ? error.message : String(error);
      throw new Error(`打开系统照片选择器失败：${message}`);
    }
    if (selected.photoUris.length === 0) {
      return undefined;
    }
    const uri = selected.photoUris[0];
    if (!uri) {
      throw new Error('系统照片选择器返回了空图片地址');
    }
    return {
      uri,
      thumbnail: await this.loadThumbnail(context, uri)
    };
  }

  async loadThumbnail(context: common.UIAbilityContext, uri: string): Promise<image.PixelMap> {
    if (!uri) {
      throw new Error('图片地址为空');
    }
    const helper = photoAccessHelper.getPhotoAccessHelper(context);
    const predicates = new dataSharePredicates.DataSharePredicates();
    predicates.equalTo('uri', uri);

    let result: photoAccessHelper.FetchResult<photoAccessHelper.PhotoAsset>;
    try {
      result = await helper.getAssets({
        predicates,
        fetchColumns: ['uri']
      });
    } catch (error) {
      const message = error instanceof Error ? error.message : String(error);
      throw new Error(`读取已选择的背景图片失败：${message}`);
    }

    try {
      if (result.getCount() === 0) {
        throw new Error('找不到已选择的背景图片，请重新选择');
      }
      const asset = await result.getFirstObject();
      return await asset.getThumbnail({ width: 1280, height: 720 });
    } finally {
      result.close();
    }
  }
}
